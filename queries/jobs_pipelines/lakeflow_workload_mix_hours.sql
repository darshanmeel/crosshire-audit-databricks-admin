-- query_id: lakeflow_workload_mix_hours
-- source: system.lakeflow.job_run_timeline
-- feeds: workload mix & hours; failed runs
-- confidence: confirmed
-- caveats: run_type JOB_RUN/SUBMIT_RUN/WORKFLOW_RUN. WORKFLOW_RUN compute is attributed to the parent notebook (do NOT double-count its DBU against the job) — kept here for run-mix counting only; dollar attribution lives in billing. execution_duration_seconds is not-populated-before-early-Dec-2025 (degrade). Counts DISTINCT run_id to net out hourly slicing of >1h runs. completed_run_rows should be read as "end-row count", not "run count".
/* databricks_audit:lakeflow_workload_mix_hours */
SELECT workspace_id, run_type, trigger_type,
       date_trunc('DAY', period_start_time) AS run_day,
       COUNT(DISTINCT run_id) AS distinct_runs,
       SUM(CASE WHEN result_state IS NOT NULL THEN 1 ELSE 0 END) AS completed_run_rows,
       SUM(execution_duration_seconds) AS execution_s_total
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= date_add(current_date(), -30)
  AND period_start_time < date_trunc('DAY', current_timestamp())
GROUP BY workspace_id, run_type, trigger_type, date_trunc('DAY', period_start_time)
