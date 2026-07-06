-- query_id: lakeflow_termination_taxonomy
-- source: system.lakeflow.job_run_timeline
-- feeds: termination taxonomy; failed runs
-- confidence: confirmed
-- caveats: The documented termination_code values cover root-cause classification + quota/limit-hit detection (e.g. WORKSPACE_RUN_LIMIT_EXCEEDED, MAX_JOB_QUEUE_SIZE_EXCEEDED, CLUSTER_ERROR, STORAGE_ACCESS_ERROR). The separate termination_type column is excluded here — its value list is UNVERIFIED (see the probe query).
/* databricks_audit:lakeflow_termination_taxonomy */
SELECT workspace_id, termination_code,
       COUNT(*)              AS run_rows,
       COUNT(DISTINCT run_id) AS distinct_runs
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= date_add(current_date(), -30)
  AND period_end_time < date_trunc('DAY', current_timestamp())
  AND result_state IS NOT NULL          -- end row only
  AND termination_code IS NOT NULL
GROUP BY workspace_id, termination_code
