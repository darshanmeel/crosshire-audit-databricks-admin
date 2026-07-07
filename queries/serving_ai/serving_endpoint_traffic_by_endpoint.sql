-- query_id: serving_endpoint_traffic_by_endpoint
-- title: Serving endpoint traffic totals over the window (request/error/token rollup)
-- domain: serving_ai   tier: deep
-- reads: system.serving.endpoint_usage, system.serving.served_entities, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.serving, system.billing; system.serving must be enabled per-metastore (empty until Model Serving is in use); system.billing is GA.
-- params: :period_days (default 30) rolling window in days
-- confidence: confirmed
-- confidence_note: Columns were verified against the AI Gateway usage-schema documentation on 2026-06-21 - re-verify if you are running this well after that date, since system-table schemas evolve.
-- read_this: One row = one endpoint's total traffic over the window. The columns that matter are request_count and last_request_date - use this as the join input for a cost-per-request or dormancy check, not as a standalone health signal.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: compute_serving_dormant_endpoints (if you want the per-served-entity dormancy read), cost_by_compute_resource (if you want the underlying billed cost trend)
-- caveats: system.serving.* is empty unless Model Serving is enabled/in use - read zero rows as "not measured", never as a true zero. Confirmed endpoint_usage columns: it is one row per request (there is no request_count column in the source table, so traffic here is COUNT(*)); status_code (integer), request_time (timestamp), served_entity_id, input_token_count/output_token_count (long). served_entities is the change-history dimension; confirmed columns include endpoint_id, endpoint_name, served_entity_id, change_time - deduped to the latest config row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC before the join, so a reconfigured entity is not double-counted. endpoint_id/endpoint_name come from served_entities (endpoint_usage itself only carries served_entity_id, not endpoint_id). net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), NOT the negotiated invoice rate (not in any system table), and excludes cloud infra/egress dollars. Cost is attributed by billing endpoint_id over the window (per-endpoint, not per-request); the rollup is pre-aggregated then LEFT JOINed, so rows are never multiplied. Serving DBUs in system.billing.usage are billed at the endpoint level, not per served entity, so cost cannot be split across entities within an endpoint - it aligns with this query's per-endpoint grain. endpoint_id is a globally-unique GUID, so the cost rollup is keyed on endpoint_id alone (workspace_id dropped from that rollup's grain); the rollup is 1:1 per endpoint so it is surfaced via MAX() inside the existing GROUP BY. This query already uses :period_days for its window throughout.
WITH entities AS (
  SELECT workspace_id, endpoint_id, endpoint_name, served_entity_id
  FROM (
    SELECT
      se.workspace_id, se.endpoint_id, se.endpoint_name, se.served_entity_id,
      ROW_NUMBER() OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
        ORDER BY se.change_time DESC
      ) AS _rn
    FROM system.serving.served_entities se
  )
  WHERE _rn = 1
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Pre-aggregated to EXACTLY this query's join grain (endpoint_id) so the LEFT JOIN is strictly 1:1
  -- and never multiplies result rows. endpoint_id is a globally-unique GUID -> keyed on id alone.
  SELECT
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
  GROUP BY u.usage_metadata.endpoint_id
)
SELECT
  ent.endpoint_id                                   AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  COUNT(*)                                          AS request_count,
  SUM(CASE WHEN eu.status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END) AS success_requests,
  SUM(CASE WHEN eu.status_code IS NOT NULL AND NOT (eu.status_code BETWEEN 200 AND 299) THEN 1 ELSE 0 END) AS error_requests,
  SUM(COALESCE(eu.input_token_count, 0))            AS input_tokens,
  SUM(COALESCE(eu.output_token_count, 0))           AS output_tokens,
  MAX(CAST(eu.request_time AS DATE))                AS last_request_date,
  -- cost columns: rollup is constant within each endpoint group (1:1), surfaced via MAX() so the
  -- existing per-endpoint grain and COUNT(*) semantics are unchanged.
  MAX(COALESCE(cr.net_dbus, 0))                     AS net_dbus,
  MAX(COALESCE(cr.est_usd_list, 0))                 AS est_usd_list
FROM system.serving.endpoint_usage eu
LEFT JOIN entities ent
  ON  eu.workspace_id     = ent.workspace_id
  AND eu.served_entity_id = ent.served_entity_id
LEFT JOIN cost_rollup cr
  ON  ent.endpoint_id = cr.endpoint_id
WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
  AND eu.request_time <  current_date()
GROUP BY ent.endpoint_id, ent.endpoint_name
ORDER BY request_count DESC, endpoint_id
