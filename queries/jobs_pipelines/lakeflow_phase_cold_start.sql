-- query_id: lakeflow_phase_cold_start
-- source: system.lakeflow.job_run_timeline
-- feeds: phase-level cold-start
-- confidence: confirmed
-- caveats: All five *_duration_seconds are "not populated before early Dec 2025" -> on short-history accounts they are NULL; rows_setup_null exposes this so the finding degrades rather than inferring zero startup overhead. queue_duration_seconds exists ONLY on job_run_timeline, not on job_task_run_timeline. (Consider PERCENTILE_APPROX on large volumes — exact PERCENTILE can be expensive.)
/* databricks_audit:lakeflow_phase_cold_start */
SELECT workspace_id, job_id,
       COUNT(DISTINCT run_id)                    AS runs,
       SUM(setup_duration_seconds)               AS setup_s_total,
       SUM(queue_duration_seconds)               AS queue_s_total,
       SUM(execution_duration_seconds)           AS execution_s_total,
       SUM(cleanup_duration_seconds)             AS cleanup_s_total,
       SUM(run_duration_seconds)                 AS run_s_total,
       PERCENTILE(setup_duration_seconds, 0.95)  AS setup_s_p95,
       PERCENTILE(queue_duration_seconds, 0.95)  AS queue_s_p95,
       SUM(CASE WHEN setup_duration_seconds IS NULL THEN 1 ELSE 0 END) AS rows_setup_null
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= date_add(current_date(), -30)
  AND period_end_time < date_trunc('DAY', current_timestamp())
  AND result_state IS NOT NULL     -- end row carries the final durations
GROUP BY workspace_id, job_id
