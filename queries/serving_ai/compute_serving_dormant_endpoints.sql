-- query_id: compute_serving_dormant_endpoints
-- title: Serving endpoints with no traffic in the window (dormant / wasted spend)
-- domain: serving_ai   tier: deep
-- reads: system.serving.served_entities, system.serving.endpoint_usage, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.serving, system.billing; system.serving must be enabled per-metastore (empty until Model Serving is in use); system.billing is GA.
-- params: :period_days (default 30) rolling window in days; :warn_low_requests (default 10) total requests over the window at/below which a served entity with some traffic still flags WARN as near-dormant
-- confidence: needs_confirmation
-- confidence_note: The dedup-to-latest-config-row join and the endpoint-level cost rollup are verified against a live workspace, but whether served_entities exposes an explicit creation flag - needed to exclude endpoints created inside the window from the dormant label - is not confirmed; verify against your own workspace before acting on borderline rows.
-- read_this: One row = a served entity (a model/version behind an endpoint). The columns that matter are last_request_date and net_dbus: last_request_date NULL means no request landed on this entity in the window, and net_dbus > 0 on that same row means you are paying DBUs for capacity nobody is calling.
-- healthy: last_request_date is not NULL and total_requests is above :warn_low_requests (field heuristic - tune :warn_low_requests for your account).
-- investigate_if: last_request_date IS NULL with net_dbus > 0 (CRITICAL - paying for zero traffic), or last_request_date IS NULL with no cost signal, or total_requests at/below :warn_low_requests (WARN) - field heuristic; tune :warn_low_requests for your account.
-- actions: 1) confirm with the owning team that the endpoint has no real consumers, then delete the served entity / endpoint (free); 2) if it must stay available for occasional use, move it to a scale-to-zero or pay-per-token serving mode so idle time is not billed (config); 3) if it must stay warm for latency SLAs, right-size the provisioned throughput to the smallest tier that meets that SLA (spend, but lower than today).
-- next: compute_serving_endpoint_usage (if you want the daily request/error/token trend before deciding), cost_by_compute_resource (if you want this endpoint's full cost history)
-- caveats: system.serving.* is empty unless Model Serving is enabled/in use - read zero rows as "not measured", never as "all endpoints dormant". served_entities is change-history, so it is deduped to the latest row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC first; endpoint_usage is then LEFT JOINed as a per-entity rollup, so an entity with no traffic keeps last_request_date = NULL and total_requests = 0. A NULL last_request_date means "no traffic observed", which is the dormant signal here - it is not the same as "recently active". A NULL can also mean the request predates the window, or that usage retention is shorter than the served_entities dimension - the label is "no requests in the last :period_days days", not "never used", and this query discloses that window via last_request_date and latest_change_date. NEEDS CONFIRMATION: whether served_entities exposes a reliable creation flag - a newly-created endpoint inside the window should not read as dormant just because it has not been called yet; latest_change_time/latest_change_date are surfaced on every row so you can apply that recency floor yourself. endpoint_usage has no request_count column (each row is one request, counted with COUNT(*)) and no endpoint_id column, so usage is rolled up and joined on (workspace_id, served_entity_id); endpoint_id is carried from the served_entities dimension side. net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), NOT the negotiated invoice rate (not available in any system table), and excludes cloud infra/egress dollars - treat it as directional. Cost is attributed by billing endpoint_id over the :period_days window (per-endpoint, not per-request); the rollup is pre-aggregated per (workspace_id, endpoint_id) before the LEFT JOIN, so rows are never multiplied. GRAIN CAVEAT: system.billing.usage has no served_entity_id - the lowest serving grain in billing is endpoint_id - so net_dbus/est_usd_list are ENDPOINT-level and repeat identically across every served-entity row of the same endpoint; do not SUM these across rows of one endpoint, you will double-count. For a dormant endpoint still showing net_dbus > 0, that DBU spend is the wasted provisioned cost. The status column below uses total_requests = 0 (i.e. last_request_date IS NULL) plus net_dbus > 0 as the CRITICAL driver; it deliberately has no NOT_ASSESSED branch, because a NULL last_request_date is itself the dormant signal here, not missing data.
WITH entities AS (
  -- served_entities is change-history; collapse to the latest config row per entity.
  SELECT
    workspace_id,
    endpoint_id,
    endpoint_name,
    served_entity_id,
    served_entity_name,
    entity_type,
    entity_name,
    entity_version,
    latest_change_time
  FROM (
    SELECT
      se.workspace_id,
      se.endpoint_id,
      se.endpoint_name,
      se.served_entity_id,
      se.served_entity_name,
      se.entity_type,
      se.entity_name,
      se.entity_version,
      MAX(se.change_time) OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
      ) AS latest_change_time,
      ROW_NUMBER() OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
        ORDER BY se.change_time DESC
      ) AS _rn
    FROM system.serving.served_entities se
  )
  WHERE _rn = 1
),
usage_rollup AS (
  -- Per-entity traffic inside the window. Entities with no traffic never appear here,
  -- so the LEFT JOIN below leaves their last_request_date NULL (the dormant signal).
  -- endpoint_usage has no endpoint_id and no request_count: roll up per (workspace_id,
  -- served_entity_id) and count rows for total_requests.
  SELECT
    eu.workspace_id,
    eu.served_entity_id,
    COUNT(*)                           AS total_requests,
    MAX(CAST(eu.request_time AS DATE)) AS last_request_date
  FROM system.serving.endpoint_usage eu
  WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
    AND eu.request_time <  current_date()
  GROUP BY eu.workspace_id, eu.served_entity_id
),
price AS (
  -- List price is pricing.default; price_end_time IS NULL is the current price.
  SELECT
    sku_name, cloud, usage_unit, price_start_time, price_end_time,
    CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Pre-aggregated ENDPOINT-level DBU + list-$ rollup, keyed on the only serving id billing exposes
  -- (usage_metadata.endpoint_id). Grouped per (workspace_id, endpoint_id) then LEFT JOINed below so
  -- result rows are never multiplied. Same :period_days window this query uses elsewhere.
  SELECT
    u.workspace_id,
    u.usage_metadata.endpoint_id                     AS endpoint_id,
    SUM(u.usage_quantity)                            AS net_dbus,
    SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.endpoint_id IS NOT NULL
    AND u.usage_date >= dateadd(day, -:period_days, current_date())
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.endpoint_id
)
SELECT
  ent.workspace_id                            AS workspace_id,
  ent.endpoint_id                             AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  ent.served_entity_id                        AS served_entity_id,
  CASE WHEN ent.served_entity_name IS NULL THEN ent.served_entity_name ELSE concat(substr(ent.served_entity_name, 1, 2), '****') END AS served_entity_name,
  ent.entity_type                             AS entity_type,
  ent.entity_name                             AS entity_name,
  ent.latest_change_time                      AS latest_change_time,
  CAST(ent.latest_change_time AS DATE)        AS latest_change_date,
  COALESCE(ur.total_requests, 0)              AS total_requests,
  ur.last_request_date                        AS last_request_date,
  -- Cost visibility (ENDPOINT-level; repeats across served-entity rows of the same endpoint):
  COALESCE(cr.net_dbus, 0)                    AS net_dbus,
  COALESCE(cr.est_usd_list, 0)                AS est_usd_list,
  -- status: worst-first band on dormancy (field heuristic; :warn_low_requests).
  CASE
    WHEN COALESCE(ur.total_requests, 0) = 0 AND COALESCE(cr.net_dbus, 0) > 0 THEN 'CRITICAL'
    WHEN COALESCE(ur.total_requests, 0) = 0                                  THEN 'WARN'
    WHEN COALESCE(ur.total_requests, 0) <= :warn_low_requests                THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM entities ent
LEFT JOIN usage_rollup ur
  ON  ent.workspace_id     = ur.workspace_id
  AND ent.served_entity_id = ur.served_entity_id
LEFT JOIN cost_rollup cr
  ON  ent.workspace_id = cr.workspace_id
  AND ent.endpoint_id  = cr.endpoint_id
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 ELSE 2 END,
  COALESCE(cr.net_dbus, 0) DESC,
  COALESCE(ur.total_requests, 0) ASC
