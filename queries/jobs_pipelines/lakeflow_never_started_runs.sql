-- query_id: lakeflow_never_started_runs
-- source: system.lakeflow.job_run_timeline
-- feeds: never-started runs
-- confidence: confirmed
-- caveats: period_start_time == period_end_time marks runs that never executed; termination_code gives the reason. Filtered to end rows to avoid false positives from clock-hour-aligned slicing.
/* databricks_audit:lakeflow_never_started_runs */
SELECT workspace_id, job_id, termination_code,
       COUNT(DISTINCT run_id) AS never_started_runs
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= date_add(current_date(), -30)
  AND period_end_time < date_trunc('DAY', current_timestamp())
  AND result_state IS NOT NULL
  AND period_start_time = period_end_time     -- never began execution
GROUP BY workspace_id, job_id, termination_code
