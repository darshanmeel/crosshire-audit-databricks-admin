-- query_id: query_shuffle_write_amplification
-- source: system.query.history
-- feeds: shuffle/write amplification
-- confidence: confirmed
-- caveats: shuffle_read_bytes -> shuffle-heavy/bad-join signal; written_files vs written_rows -> small-files-on-write / write amplification. WHERE guards non-write/non-shuffle rows. Regional. Classic-cluster statements absent.
/* databricks_audit:query_shuffle_write_amplification */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by,
       statement_type,
       COUNT(*) AS query_count,
       SUM(shuffle_read_bytes) AS shuffle_read_bytes_sum,
       SUM(written_bytes)      AS written_bytes_sum,
       SUM(written_rows)       AS written_rows_sum,
       SUM(written_files)      AS written_files_sum,
       SUM(read_bytes)         AS read_bytes_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
  AND (shuffle_read_bytes > 0 OR written_bytes > 0)
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id, executed_by, statement_type
