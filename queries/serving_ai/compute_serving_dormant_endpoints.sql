-- query_id: compute_serving_dormant_endpoints
-- source: system.serving.served_entities
-- feeds: compute_serving_dormant_endpoints (gov-5 dormant arm) — endpoints/served-entities with no request traffic in the window
-- confidence: needs_confirmation
-- caveats: system.serving.* is empty unless Model Serving is enabled/in use — preflight skip-sentinels it and the finding degrades to not_assessed (never a fake zero "all endpoints dormant"). DORMANT must-fix: served_entities is the DIMENSION and is change-history, so it is deduped to the latest row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC FIRST; endpoint_usage is then LEFT JOINed as a per-entity rollup so an entity with NO usage row keeps last_request_date = NULL and total_requests = 0. A NULL last-usage means "no traffic observed", which is the dormant signal — it is NOT treated as "recently active". last_request_date NULL can also mean the request simply predates the window or that usage retention is shorter than the dimension; the finding labels dormant as "no requests in the last N days", not "never used", and discloses the window. NEEDS WORKSPACE CONFIRMATION: that endpoint_creator/created flags exist on served_entities — newly-created endpoints inside the window should not read as dormant, so the latest change_time is carried out as a recency floor and the finding excludes entities whose only change is newer than the window start. NOTE: endpoint_usage has no request_count column (each row is one request, so requests are counted with COUNT(*)) and no endpoint_id column, so usage is rolled up and joined on (workspace_id, served_entity_id); endpoint_id is carried from the served_entities dimension side.
-- COST CAVEATS (added):
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing endpoint_id over the :period_days window (per-endpoint), not per
--   request. The cost rollup is pre-aggregated per (workspace_id, endpoint_id) then LEFT JOINed, so
--   finding rows are never multiplied.
-- GRAIN CAVEAT: system.billing.usage has NO served_entity_id — the lowest serving grain in billing is
--   endpoint_id. So net_dbus/est_usd_list are ENDPOINT-level and REPEAT identically across every
--   served-entity row of the same endpoint. Do NOT SUM these across rows of one endpoint (double-count).
--   For a dormant endpoint still showing net_dbus > 0, that DBU spend is the wasted provisioned cost.
/* databricks_audit:compute_serving_dormant_endpoints */
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
  -- Pre-aggregated ENDPOINT-level DBU + list-$ rollup, keyed on the ONLY serving id billing exposes
  -- (usage_metadata.endpoint_id). Grouped per (workspace_id, endpoint_id) then LEFT JOINed below so
  -- finding rows are never multiplied. Same :period_days window the finding uses.
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
  COALESCE(cr.est_usd_list, 0)                AS est_usd_list
FROM entities ent
LEFT JOIN usage_rollup ur
  ON  ent.workspace_id     = ur.workspace_id
  AND ent.served_entity_id = ur.served_entity_id
LEFT JOIN cost_rollup cr
  ON  ent.workspace_id = cr.workspace_id
  AND ent.endpoint_id  = cr.endpoint_id