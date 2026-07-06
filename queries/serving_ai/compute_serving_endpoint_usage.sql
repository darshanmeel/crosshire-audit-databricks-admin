-- query_id: compute_serving_endpoint_usage
-- source: system.serving.endpoint_usage
-- feeds: compute_serving_endpoint_health (gov-5) — per-endpoint request volume, success vs error, token throughput
-- confidence: needs_confirmation
-- caveats: system.serving.* is empty unless Model Serving is in use (and the serving schema is enabled) — collection preflight skip-sentinels it when absent, and the finding degrades to not_assessed rather than reporting a fake zero. The served_entities dimension is CHANGE-HISTORY (one row per config change) and is deduped to the latest row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC before the join, so a renamed/reconfigured entity is not counted twice. NEEDS WORKSPACE CONFIRMATION: exact endpoint_usage column names/grain. This query assumes the documented shape — request_time (timestamp), workspace_id, endpoint_id, served_entity_id, request_count, served_entity_input_tokens, served_entity_output_tokens, and a status/HTTP-code column. The status literal (status_code) and token column names are NOT verified against this workspace; the finding guards every column with a presence check and treats absent columns as "unknown", never as a finding. usage_quantity/DBUs live in system.billing.usage, NOT here — this table is a request/token counter, not a dollar source.
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
  eu.endpoint_id                       AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  eu.served_entity_id                  AS served_entity_id,
  CASE WHEN ent.served_entity_name IS NULL THEN ent.served_entity_name ELSE concat(substr(ent.served_entity_name, 1, 2), '****') END AS served_entity_name,
  ent.entity_type                      AS entity_type,
  ent.entity_name                      AS entity_name,
  -- NEEDS WORKSPACE CONFIRMATION: status_code is the assumed HTTP-status column on
  -- endpoint_usage; classify 2xx as success, everything else as error. If the real
  -- column differs, every request below collapses into the 'unknown' bucket and the
  -- finding reports success rate as unknown rather than fabricating one.
  SUM(CASE WHEN eu.status_code BETWEEN 200 AND 299 THEN eu.request_count ELSE 0 END) AS success_requests,
  SUM(CASE WHEN eu.status_code IS NOT NULL AND NOT (eu.status_code BETWEEN 200 AND 299)
           THEN eu.request_count ELSE 0 END)                                         AS error_requests,
  SUM(eu.request_count)                                                              AS total_requests,
  -- Token throughput is a separate magnitude from request counts (never summed with them).
  SUM(COALESCE(eu.served_entity_input_tokens, 0))                                    AS input_tokens,
  SUM(COALESCE(eu.served_entity_output_tokens, 0))                                   AS output_tokens
FROM system.serving.endpoint_usage eu
LEFT JOIN entities ent
  ON  eu.workspace_id     = ent.workspace_id
  AND eu.endpoint_id      = ent.endpoint_id
  AND eu.served_entity_id = ent.served_entity_id
WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
  AND eu.request_time <  current_date()
GROUP BY
  CAST(eu.request_time AS DATE),
  eu.workspace_id,
  eu.endpoint_id,
  ent.endpoint_name,
  eu.served_entity_id,
  ent.served_entity_name,
  ent.entity_type,
  ent.entity_name
