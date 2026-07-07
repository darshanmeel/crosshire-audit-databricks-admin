-- query_id: query_pruning_effectiveness
-- title: File-pruning effectiveness per query group
-- domain: performance   tier: standard
-- reads: system.query.history
-- requires: SELECT on system.query; GA (system.query.history is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_prune_ratio (default 0.5) pruning ratio (pruned_files / (pruned_files + read_files)) below which a group flags WARN; :crit_prune_ratio (default 0.2) ... below which it flags CRITICAL
-- confidence: confirmed
-- confidence_note: Columns verified against system.query.history in a live workspace.
-- read_this: One row = a day + warehouse + identity + statement_type whose queries pruned or read files during a scan. The columns that matter are pruned_files_sum and read_files_sum - together they give the pruning ratio (pruned / (pruned + read)); a low ratio on a repeating group means partition or file layout, or the query's own predicates, are not letting Databricks skip files it should be skipping.
-- healthy: pruning ratio at/above :warn_prune_ratio (field heuristic - tune :warn_prune_ratio for your account).
-- investigate_if: pruning ratio below :warn_prune_ratio (WARN) or below :crit_prune_ratio (CRITICAL) - field heuristic; a stable low ratio on the same table/warehouse combination over several days is the real signal, not one bad day.
-- actions: 1) check whether your WHERE/JOIN predicates actually align with the table's partition, Z-order, or liquid-clustering columns (free); 2) run OPTIMIZE / re-cluster the table on the columns these queries filter by (config); 3) if the table is still poorly organized after re-clustering, repartition or rewrite it with a layout that matches the query pattern (spend - a rewrite cost).
-- next: query_local_spillage (if the same warehouse also spills, pointing to under-provisioned memory on top of poor pruning), query_shuffle_write_amplification (if the same reads are also shuffle-heavy)
-- caveats: Pruning effectiveness here is pruned_files / (pruned_files + read_files) - there is no total-partition denominator and no per-table rollup in system tables, so this is per-statement-group only, never "percent of your table pruned." read_partitions is a POST-pruning count (partitions actually read after pruning), not partitions pruned - do not read it as the inverse of pruned_files. The WHERE clause only includes rows where pruning or reading actually happened, guarding out non-scan statements; whether Databricks reports NULL or 0 for these counters on a non-scan statement is undocumented, so treat a missing row as "not a scan," not "perfect pruning." This table is regional.
-- system.query.history only captures queries run on SQL warehouses or serverless compute; queries on classic all-purpose or job clusters never appear here, so poor pruning on those clusters is entirely invisible to this analysis.
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
       SUM(read_rows)       AS read_rows_sum,
       -- status: worst-first band on the pruning ratio pruned/(pruned+read) (field heuristic; :warn_prune_ratio / :crit_prune_ratio).
       CASE
         WHEN SUM(pruned_files) + SUM(read_files) = 0 THEN 'NOT_ASSESSED'
         WHEN SUM(pruned_files) / (SUM(pruned_files) + SUM(read_files)) < :crit_prune_ratio THEN 'CRITICAL'
         WHEN SUM(pruned_files) / (SUM(pruned_files) + SUM(read_files)) < :warn_prune_ratio THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL :period_days DAYS
  AND start_time < current_date()
  AND (pruned_files > 0 OR read_files > 0)
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id, executed_by, statement_type
ORDER BY (pruned_files_sum * 1.0 / NULLIF(pruned_files_sum + read_files_sum, 0)) ASC
