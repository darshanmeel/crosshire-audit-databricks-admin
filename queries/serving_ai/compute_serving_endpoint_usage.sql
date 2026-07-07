-- query_id: compute_serving_endpoint_usage
-- source: system.serving.endpoint_usage
-- feeds: compute_serving_endpoint_health (gov-5) — per-endpoint request volume, success vs error, token throughput
-- confidence: needs_confirmation
-- caveats: system.serving.* is empty unless Model Serving is in use (and the serving schema is enabled) — collection preflight skip-sentinels it when absent, and the finding degrades to not_assessed rather than reporting a fake zero. The served_entities dimension is CHANGE-HISTORY (one row per config change) and is deduped to the latest row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC before the join, so a renamed/reconfigured entity is not counted twice. endpoint_usage has no endpoint_id column, so the join is on (workspace_id, served_entity_id) and endpoint_id is sourced from served_entities (ent.endpoint_id). endpoint_usage is one row per request (no request_count column), so request volumes are COUNT(*)/CASE-based. Verified column names: request_time (timestamp), workspace_id, served_entity_id, status_code (int HTTP status), input_token_count, output_token_count. usage_quantity/DBUs live in system.billing.usage, NOT here — this table is a request/token counter, not a dollar source.
/* databricks_audit:compute_serving_endpoint_usage */
WITH entities AS (
  -- served_entities is change-history; keep only the latest config row per entity.
  SELECT
    workspace_id,
    endpoint_id,
    endpoint_name,
    served_entity_id,
    served_entity_name,
    entity_type,
    entity_name,
    entity_version
  FROM (
    SELECT
      se.*,
      ROW_NUMBER() OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
        ORDER BY se.change_time DESC
      ) AS _rn
    FROM system.serving.served_entities se
  )
  WHERE _rn = 1
)
SELECT
  CAST(eu.request_time AS DATE)        AS usage_date,
  eu.workspace_id                      AS workspace_id,
  ent.endpoint_id                      AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  eu.served_entity_id                  AS served_entity_id,
  CASE WHEN ent.served_entity_name IS NULL THEN ent.served_entity_name ELSE concat(substr(ent.served_entity_name, 1, 2), '****') END AS served_entity_name,
  ent.entity_type                      AS entity_type,
  ent.entity_name                      AS entity_name,
  -- status_code is the HTTP-status column on endpoint_usage; classify 2xx as success,
  -- everything else as error. endpoint_usage is one row per request, so counts are
  -- COUNT(*)/CASE-based rather than a summed request_count column.
  SUM(CASE WHEN eu.status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END) AS success_requests,
  SUM(CASE WHEN eu.status_code IS NOT NULL AND NOT (eu.status_code BETWEEN 200 AND 299)
           THEN 1 ELSE 0 END)                                         AS error_requests,
  COUNT(*)                                                            AS total_requests,
  -- Token throughput is a separate magnitude from request counts (never summed with them).
  SUM(COALESCE(eu.input_token_count, 0))                             AS input_tokens,
  SUM(COALESCE(eu.output_token_count, 0))                            AS output_tokens
FROM system.serving.endpoint_usage eu
LEFT JOIN entities ent
  ON  eu.workspace_id     = ent.workspace_id
  AND eu.served_entity_id = ent.served_entity_id
WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
  AND eu.request_time <  current_date()
GROUP BY
  CAST(eu.request_time AS DATE),
  eu.workspace_id,
  ent.endpoint_id,
  ent.endpoint_name,
  eu.served_entity_id,
  ent.served_entity_name,
  ent.entity_type,
  ent.entity_name
