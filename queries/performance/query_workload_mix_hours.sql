-- query_id: query_workload_mix_hours
-- source: system.query.history
-- feeds: workload mix/hours
-- confidence: confirmed
-- caveats: Day × hour-of-day × compute × statement_type × user histogram. produced_rows (rows returned) is distinct from read_rows. SQL-warehouse + serverless only. Regional. Excludes incomplete current day.
/* databricks_audit:query_workload_mix_hours */
SELECT date(start_time) AS day, workspace_id, hour(start_time) AS hour_of_day,
       compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       statement_type,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by,
       COUNT(*) AS query_count,
       SUM(CASE WHEN execution_status = 'FINISHED' THEN 1 ELSE 0 END) AS finished_count,
       SUM(total_duration_ms)     AS total_duration_ms_sum,
       SUM(execution_duration_ms) AS execution_duration_ms_sum,
       SUM(read_bytes)            AS read_bytes_sum,
       SUM(produced_rows)         AS produced_rows_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
GROUP BY date(start_time), workspace_id, hour(start_time), compute.type, compute.warehouse_id, statement_type, executed_by
