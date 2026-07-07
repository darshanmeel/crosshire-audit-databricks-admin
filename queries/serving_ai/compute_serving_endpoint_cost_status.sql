-- query_id: compute_serving_endpoint_cost_status
-- title: Serving endpoint cost, idle, and usage-tracking status
-- domain: serving_ai   tier: standard
-- reads: system.billing.usage, system.billing.list_prices, system.serving.served_entities, system.serving.endpoint_usage, system.access.workspaces_latest
-- requires: SELECT on system.billing, system.serving, system.access; the serving and access system schemas enabled; billing is GA, serving + workspaces_latest are Public Preview
-- params: :period_days (default 30) analysis window in days for requests and cost; :retention_days (default 90) the full endpoint_usage retention window, used to tell "usage tracking off" from "idle in window"; :warn_low_requests (default 10) endpoint requests over the window at or below which a billed endpoint flags WARN; :top_n (default 200) row cap
-- confidence: needs_confirmation
-- confidence_note: every column is verified against the workspace system-schema dump; the tracking_status classification is a heuristic inferred from whether a billed endpoint has any serving telemetry, not a Databricks-reported flag.
-- read_this: One row = one endpoint that BILLED in the window (any serving product, including Vector Search), with its DBUs, a list-price dollar estimate, request volume, and a tracking_status. The columns that matter are est_usd_list (spend) and tracking_status / status - they separate "usage tracking is OFF" (spend but no telemetry) from "truly idle" (tracked but zero requests).
-- healthy: status = OK - the endpoint has request volume proportional to its spend.
-- investigate_if: status = CRITICAL (tracked, still billing, zero requests in the window = idle waste) or WARN (very low requests, or spend with usage tracking off so idle cannot be confirmed) - field heuristic; tune :warn_low_requests for your account.
-- actions: 1) scale-to-zero or delete endpoints flagged CRITICAL idle (free); 2) for spend-with-tracking-off rows, enable AI Gateway usage tracking on the endpoint so idle can actually be measured (config); 3) right-size provisioned throughput or move a low-traffic endpoint to pay-per-token (spend).
-- next: compute_serving_endpoint_usage (per-endpoint request and token detail), cost_by_serving_endpoint (the raw DBU cost split by usage_type), cost_vector_search_spend (for the Vector Search endpoints this flags NOT_ASSESSED)
-- caveats: ANCHORED ON system.billing.usage so it sees EVERY endpoint-billed product (MODEL_SERVING and VECTOR_SEARCH), then LEFT JOINs the serving tables - which only cover Model Serving endpoints that have AI Gateway usage tracking enabled. tracking_status therefore reports: NOT_ASSESSED for Vector Search (no serving telemetry exists) and for endpoints that bill but are absent from served_entities; "usage tracking off" when there is spend but zero tracked rows across :retention_days; "idle" when tracked but zero requests in :period_days. served_entities is change-history, deduped to the latest row per (workspace_id, endpoint_id, served_entity_id). endpoint_usage has NO endpoint_id and NO request_count, so requests are COUNT(*) rolled up per served_entity_id and mapped to endpoint_id through served_entities. Cost = usage_quantity x list_prices.pricing.default, a LIST-PRICE ESTIMATE (not the negotiated invoice; DBU-only, excludes cloud infra/egress). endpoint_name and served_entity_name are partial-masked. workspaces_latest is Public Preview (LEFT JOIN; workspace_name may be null). Set :retention_days to roughly your endpoint_usage retention (~90 days) so "usage tracking off" is not misread as idle.
-- Route-optimized custom Model Serving endpoints never support usage tracking, so they surface as "usage tracking off" (WARN) even though it can never be enabled - not an actionable config gap for those.
WITH entities AS (   -- served_entities is change-history -> collapse to the latest config row per entity
  SELECT workspace_id, endpoint_id, endpoint_name, served_entity_id, served_entity_name,
         entity_type, entity_name, entity_version, latest_change_time
  FROM (
    SELECT se.workspace_id, se.endpoint_id, se.endpoint_name, se.served_entity_id,
           se.served_entity_name, se.entity_type, se.entity_name, se.entity_version,
           MAX(se.change_time) OVER (PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id) AS latest_change_time,
           ROW_NUMBER() OVER (PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id ORDER BY se.change_time DESC) AS _rn
    FROM system.serving.served_entities se
  ) WHERE _rn = 1
),
ent_map AS (   -- served_entity_id -> endpoint_id, so endpoint_usage (which has no endpoint_id) can roll up to endpoint level
  SELECT DISTINCT workspace_id, endpoint_id, served_entity_id FROM entities
),
usage_entity AS (   -- per served entity, inside the analysis window
  SELECT eu.workspace_id, eu.served_entity_id,
         COUNT(*) AS total_requests,
         MAX(CAST(eu.request_time AS DATE)) AS last_request_date
  FROM system.serving.endpoint_usage eu
  WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
    AND eu.request_time <  current_date()
  GROUP BY eu.workspace_id, eu.served_entity_id
),
usage_endpoint AS (   -- requests rolled up to endpoint, inside the analysis window
  SELECT m.workspace_id, m.endpoint_id,
         SUM(ue.total_requests) AS ep_requests,
         MAX(ue.last_request_date) AS ep_last_request_date
  FROM usage_entity ue
  JOIN ent_map m ON ue.workspace_id = m.workspace_id AND ue.served_entity_id = m.served_entity_id
  GROUP BY m.workspace_id, m.endpoint_id
),
usage_ever AS (   -- ANY tracked row over the full retention window -> distinguishes "tracking off" from "idle in window"
  SELECT m.workspace_id, m.endpoint_id, COUNT(*) AS ever_requests
  FROM system.serving.endpoint_usage eu
  JOIN ent_map m ON eu.workspace_id = m.workspace_id AND eu.served_entity_id = m.served_entity_id
  WHERE eu.request_time >= dateadd(day, -:retention_days, current_date())
  GROUP BY m.workspace_id, m.endpoint_id
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost AS (   -- billing per (workspace, endpoint, product); VS carries endpoint_name, model serving carries endpoint_id -> COALESCE
  SELECT u.workspace_id,
         u.usage_metadata.endpoint_id                     AS endpoint_id,
         u.usage_metadata.endpoint_name                   AS endpoint_name_billing,
         u.billing_origin_product                         AS product,
         SUM(u.usage_quantity)                            AS net_dbus,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND (u.usage_metadata.endpoint_id IS NOT NULL OR u.usage_metadata.endpoint_name IS NOT NULL)
    AND u.usage_date >= dateadd(day, -:period_days, current_date())
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.endpoint_id, u.usage_metadata.endpoint_name, u.billing_origin_product
),
cost_ep AS (   -- collapse products -> one row per endpoint (total cost), keep the product list
  SELECT workspace_id,
         COALESCE(endpoint_id, endpoint_name_billing)              AS endpoint_key,
         MAX(endpoint_id)                                          AS endpoint_id,
         MAX(endpoint_name_billing)                                AS endpoint_name_billing,
         SUM(net_dbus)                                             AS net_dbus,
         SUM(est_usd_list)                                         AS est_usd_list,
         array_join(collect_set(product), ', ')                    AS products,
         MAX(CASE WHEN product = 'VECTOR_SEARCH' THEN 1 ELSE 0 END) AS is_vs
  FROM cost GROUP BY workspace_id, COALESCE(endpoint_id, endpoint_name_billing)
)
SELECT
  ce.workspace_id,
  w.workspace_name,
  ce.endpoint_id,
  CASE WHEN COALESCE(ent.endpoint_name, ce.endpoint_name_billing) IS NULL THEN NULL
       ELSE concat(substr(COALESCE(ent.endpoint_name, ce.endpoint_name_billing), 1, 2), '****') END AS endpoint_name,
  ce.products,
  ent.served_entity_id,
  CASE WHEN ent.served_entity_name IS NULL THEN NULL
       ELSE concat(substr(ent.served_entity_name, 1, 2), '****') END AS served_entity_name,
  ent.entity_type,                                       -- FOUNDATION_MODEL / CUSTOM_MODEL / EXTERNAL_MODEL / FEATURE_SPEC ...
  ent.entity_name,
  ent.entity_version,
  ent.latest_change_time,
  ROUND(ce.net_dbus, 1)                                  AS net_dbus,
  ROUND(ce.est_usd_list, 2)                              AS est_usd_list,
  COALESCE(ue.total_requests, 0)                         AS entity_requests_window,
  ue.last_request_date                                   AS entity_last_request_date,
  COALESCE(uep.ep_requests, 0)                           AS endpoint_requests_window,
  uep.ep_last_request_date,
  -- Is the "0 requests" real, or just untracked? (free-text detail; the enum band is `status`)
  CASE
    WHEN ce.is_vs = 1                                            THEN 'Vector Search - no serving-table telemetry (see cost_vector_search_spend)'
    WHEN ent.endpoint_id IS NULL                                THEN 'bills but not in served_entities (not a tracked model-serving endpoint)'
    WHEN COALESCE(uev.ever_requests, 0) = 0 AND ce.net_dbus > 0  THEN 'usage tracking likely OFF - spend but zero tracked rows in retention'
    WHEN COALESCE(uep.ep_requests, 0) = 0                        THEN 'tracking ON - idle in window (had traffic within retention)'
    ELSE                                                             'tracking ON - active'
  END AS tracking_status,
  CASE
    WHEN ce.is_vs = 1                                                THEN 'NOT_ASSESSED'   -- Vector Search: no serving telemetry
    WHEN ent.endpoint_id IS NULL                                    THEN 'NOT_ASSESSED'   -- bills but not a tracked model-serving endpoint
    WHEN COALESCE(uev.ever_requests, 0) = 0 AND ce.net_dbus > 0     THEN 'WARN'            -- spend but tracking off: enable tracking, do not call it idle
    WHEN COALESCE(uep.ep_requests, 0) = 0 AND ce.net_dbus > 0       THEN 'CRITICAL'        -- tracked + spend + zero requests = truly idle
    WHEN COALESCE(uep.ep_requests, 0) <= :warn_low_requests         THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM cost_ep ce
LEFT JOIN entities        ent ON ent.workspace_id = ce.workspace_id AND ent.endpoint_id = ce.endpoint_id
LEFT JOIN usage_entity    ue  ON ue.workspace_id  = ent.workspace_id AND ue.served_entity_id = ent.served_entity_id
LEFT JOIN usage_endpoint  uep ON uep.workspace_id = ce.workspace_id AND uep.endpoint_id = ce.endpoint_id
LEFT JOIN usage_ever      uev ON uev.workspace_id = ce.workspace_id AND uev.endpoint_id = ce.endpoint_id
LEFT JOIN system.access.workspaces_latest w ON w.workspace_id = ce.workspace_id
ORDER BY
  CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 ELSE 3 END,
  ce.net_dbus DESC, endpoint_requests_window ASC
LIMIT :top_n
