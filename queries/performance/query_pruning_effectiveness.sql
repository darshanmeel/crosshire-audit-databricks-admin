-- query_id: query_pruning_effectiveness
-- source: system.query.history
-- feeds: pruning (pruned_files/read_files)
-- confidence: confirmed
-- caveats: File-pruning effectiveness = pruned_files / (pruned_files + read_files). NO total-partition denominator and NO per-table rollup exist (per-statement only). read_partitions is a post-pruning count — label it as such, not "partitions pruned". The WHERE guards non-scan statements (NULL-vs-0 for non-scan counters is undocumented — see checklist). Regional.
/* databricks_audit:query_pruning_effectiveness */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by, statement_type,
       COUNT(*) AS query_count,
       SUM(pruned_files)    AS pruned_files_sum,
       SUM(read_files)      AS read_files_sum,
       SUM(read_partitions) AS read_partitions_sum,
       SUM(read_bytes)      AS read_bytes_sum,
       SUM(read_rows)       AS read_rows_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
  AND (pruned_files > 0 OR read_files > 0)
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id, executed_by, statement_type
