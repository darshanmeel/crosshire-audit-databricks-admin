-- query_id: query_local_spillage
-- source: system.query.history
-- feeds: local spillage
-- confidence: confirmed
-- caveats: Local spill ONLY — spilled_remote_bytes does NOT exist in Databricks (remote-spill finding renders "not assessed"). The engine renames spilled_local_bytes -> disk_bytes_spilled downstream (databricks_audit/databricks/collection/queries.sql, consumed in findings/workload.py) — the collector/loader must map it. Regional. Classic-cluster spills absent.
/* databricks_audit:query_local_spillage */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by,
       COUNT(*) AS spilling_query_count,
       SUM(spilled_local_bytes) AS spilled_local_bytes_sum,
       MAX(spilled_local_bytes) AS spilled_local_bytes_max,
       SUM(total_duration_ms)     AS total_duration_ms_sum,
       SUM(execution_duration_ms) AS execution_duration_ms_sum,
       SUM(shuffle_read_bytes)    AS shuffle_read_bytes_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
  AND spilled_local_bytes > 0
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id, executed_by
