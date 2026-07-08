-- query_id: lakeflow_workload_mix_hours
-- title: Job run workload mix by run type, trigger, and day
-- domain: jobs_pipelines   tier: lite
-- reads: system.lakeflow.job_run_timeline
-- requires: SELECT on system.lakeflow; GA (execution_duration_seconds was added early Dec 2025)
-- empty_if: schema_not_enabled
-- params: :period_days (default 30) rolling window in days
-- confidence: confirmed
-- confidence_note: the run_type values (JOB_RUN/SUBMIT_RUN/WORKFLOW_RUN) and the WORKFLOW_RUN compute-attribution note were verified against system.lakeflow.job_run_timeline in a live workspace.
-- read_this: One row = a (workspace, run_type, trigger_type, day) combination. Use distinct_runs and execution_s_total to see your run-type/trigger mix and daily volume before drilling into a specific failure or cost finding.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: lakeflow_failed_runs (drill into failures within a given run_type/trigger_type), lakeflow_pipeline_cost (drill into DBU cost for the pipeline-driven share of this mix)
-- caveats: run_type is one of JOB_RUN/SUBMIT_RUN/WORKFLOW_RUN. WORKFLOW_RUN compute is attributed to the parent notebook, not the job - do not double-count its DBUs against the job from this table; this query is for run-mix counting only, dollar attribution lives in the billing-domain queries. execution_duration_seconds is not populated before early Dec 2025, so treat a low/zero execution_s_total on an older account as degraded, not as truly idle. This counts DISTINCT run_id to net out the hourly slicing of runs over 1 hour. completed_run_rows should be read as an end-row count, not a run count (that is distinct_runs).
SELECT workspace_id, run_type, trigger_type,
       date_trunc('DAY', period_start_time) AS run_day,
       COUNT(DISTINCT run_id) AS distinct_runs,
       SUM(CASE WHEN result_state IS NOT NULL THEN 1 ELSE 0 END) AS completed_run_rows,
       SUM(execution_duration_seconds) AS execution_s_total
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= dateadd(day, -:period_days, current_date())
  AND period_start_time < date_trunc('DAY', current_timestamp())
GROUP BY workspace_id, run_type, trigger_type, date_trunc('DAY', period_start_time)
ORDER BY workspace_id, run_day DESC
