-- query_id: lakeflow_failed_runs
-- source: system.lakeflow.job_run_timeline
-- feeds: failed runs; termination taxonomy; workload mix & hours
-- confidence: confirmed
-- caveats: Failed filter result_state IN ('FAILED','ERROR','TIMED_OUT') is the documented set; SKIPPED/CANCELLED/BLOCKED are intentionally not counted as failed. COUNT(*) (rows) != COUNT(DISTINCT run_id) because retries repeat the run_id.
/* databricks_audit:lakeflow_failed_runs */
WITH end_rows AS (
  SELECT workspace_id, job_id, run_id, run_type, trigger_type,
         result_state, termination_code, period_start_time, period_end_time
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())   -- drop incomplete current day
    AND result_state IS NOT NULL                                   -- end row only
)
SELECT workspace_id, run_type, trigger_type, result_state, termination_code,
       COUNT(*)              AS run_rows,
       COUNT(DISTINCT run_id) AS distinct_runs,
       SUM(CASE WHEN result_state IN ('FAILED','ERROR','TIMED_OUT') THEN 1 ELSE 0 END) AS failed_run_rows
FROM end_rows
GROUP BY workspace_id, run_type, trigger_type, result_state, termination_code
