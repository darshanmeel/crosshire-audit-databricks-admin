-- query_id: lakeflow_job_queue_time
-- source: system.lakeflow.job_run_timeline
-- feeds: Job Health page — queue-time analysis, jobs waiting on capacity (reliability-2)
-- confidence: needs_confirmation
-- caveats: queue_duration_seconds is "not populated before late Nov 2025" -> on short-history accounts it is NULL for every run. We expose runs_queue_null separately so a fully-NULL column degrades to "not assessed — column not yet populated" downstream rather than being read as zero queue time (a NULL is unknown, never "no queue"). queue_duration_seconds lives ONLY on job_run_timeline (not on job_task_run_timeline). Populated only in the run END row (>1h runs slice hourly) -> filtered to result_state IS NOT NULL so a single run's intermediate hourly slices are not counted. job_id unique only within a workspace -> all per-job grouping is on (workspace_id, job_id). PERCENTILE takes a FRACTION in [0,1]; 0.95 is correct (a value > 1 errors at runtime). No dollars: queue seconds are not a billing unit and Databricks publishes no DBU->$ rate.
/* databricks_audit:lakeflow_job_queue_time */
WITH end_rows AS (
  SELECT workspace_id, job_id, run_id, queue_duration_seconds
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= dateadd(day, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())   -- drop incomplete current day
    AND result_state IS NOT NULL                                   -- end row only
)
SELECT workspace_id, job_id,
       COUNT(DISTINCT run_id)                                   AS distinct_runs,
       SUM(queue_duration_seconds)                              AS queue_s_total,
       percentile_approx(queue_duration_seconds, 0.95)         AS queue_s_p95,
       SUM(CASE WHEN queue_duration_seconds IS NULL THEN 1 ELSE 0 END) AS runs_queue_null
FROM end_rows
GROUP BY workspace_id, job_id
