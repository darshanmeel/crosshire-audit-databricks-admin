-- query_id: serving_endpoint_traffic_by_endpoint
-- source: system.serving.endpoint_usage JOIN system.serving.served_entities
-- feeds: cost_serving_cost_mode_efficiency (gov-7) — per-endpoint request COUNT in the window, to cross against billed serving mode
-- confidence: confirmed (columns verified against the configure-ai-gateway usage-schema page 2026-06-21)
-- caveats: system.serving.* is empty unless Model Serving is enabled/in use — preflight skip-sentinels it and the finding degrades to not_assessed (never a fake zero). CONFIRMED endpoint_usage columns: it is ONE ROW PER REQUEST (there is NO request_count column), so traffic = COUNT(*); status_code (INTEGER), request_time (TIMESTAMP), served_entity_id, input_token_count/output_token_count (LONG). served_entities is the change-history DIMENSION; confirmed columns include endpoint_id, endpoint_name, served_entity_id, change_time — deduped to the latest config row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC before the join so a reconfigured entity is not double-counted. endpoint_id/endpoint_name come from served_entities (endpoint_usage carries served_entity_id, not endpoint_id).
/* databricks_audit:serving_endpoint_traffic_by_endpoint */
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
)
SELECT
  ent.endpoint_id                                   AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  COUNT(*)                                          AS request_count,
  SUM(CASE WHEN eu.status_code BETWEEN 200 AND 299 THEN 1 ELSE 0 END) AS success_requests,
  SUM(CASE WHEN eu.status_code IS NOT NULL AND NOT (eu.status_code BETWEEN 200 AND 299) THEN 1 ELSE 0 END) AS error_requests,
  SUM(COALESCE(eu.input_token_count, 0))            AS input_tokens,
  SUM(COALESCE(eu.output_token_count, 0))           AS output_tokens,
  MAX(CAST(eu.request_time AS DATE))                AS last_request_date
FROM system.serving.endpoint_usage eu
LEFT JOIN entities ent
  ON  eu.workspace_id     = ent.workspace_id
  AND eu.served_entity_id = ent.served_entity_id
WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
  AND eu.request_time <  current_date()
GROUP BY ent.endpoint_id, ent.endpoint_name
