-- query_id: query_per_query_estimate_lane
-- source: system.query.history
-- feeds: per-query ESTIMATE lane
-- confidence: confirmed
-- caveats: ESTIMATE-LANE INPUT ONLY — there is NO per-query DBU/dollar column. Cost is allocated downstream from system.billing.usage hourly warehouse DBU, weighted by execution_duration_ms (net of waiting_for_compute) optionally × total_task_duration_ms/read_bytes, reconciled so per-query estimates SUM to metered DBU. Serverless rows have warehouse_id NULL (excluded here; serverless cost attaches via usage_metadata.job_id elsewhere). No query_hash -> no same-shape grouping. Result can be large — bound the period or add a duration threshold. Regional + billing global: attribute only within-region. Classic clusters absent.
/* databricks_audit:query_per_query_estimate_lane */
SELECT date_trunc('HOUR', start_time) AS usage_hour, workspace_id,
       compute.warehouse_id AS warehouse_id, compute.type AS compute_type,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by,
       statement_id, statement_type,
       execution_duration_ms, waiting_for_compute_duration_ms, total_task_duration_ms,
       read_bytes, total_duration_ms
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
  AND execution_status = 'FINISHED'
  AND from_result_cache = false
  AND execution_duration_ms > 0
  AND compute.warehouse_id IS NOT NULL
