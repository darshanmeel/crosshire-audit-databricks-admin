-- query_id: lakeflow_job_queue_time
-- title: Job queue time by workspace and job
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.job_run_timeline
-- requires: SELECT on system.lakeflow; GA (queue_duration_seconds was added late Nov 2025)
-- params: :period_days (default 30) rolling window in days; :warn_queue_p95_s (default 60) 95th-percentile queue seconds that flags WARN; :crit_queue_p95_s (default 300) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: queue_duration_seconds is not populated before late Nov 2025, so on a short-history account it is NULL for every run; runs_queue_null exposes that so this query degrades instead of reading NULL as zero queue time.
-- read_this: One row = a job in the window. The column that matters is queue_s_p95 - the 95th-percentile seconds a run waited before starting; queue_s_total is the sum across all its runs. Consistently high p95 on the same job means it is waiting on capacity, not a one-off traffic spike.
-- healthy: queue_s_p95 below :warn_queue_p95_s seconds - field heuristic; tune :warn_queue_p95_s for your account.
-- investigate_if: queue_s_p95 at/above :warn_queue_p95_s (WARN) or :crit_queue_p95_s (CRITICAL) seconds - field heuristic; also check runs_queue_null before trusting a "0" queue time on a short-history account.
-- actions: 1) stagger the job's schedule off the top of the hour and away from other jobs sharing the same warehouse (free); 2) move the job onto its own job cluster or a warehouse with autoscaling headroom (config); 3) add cluster capacity or move to serverless so runs stop queuing behind each other (spend).
-- next: lakeflow_phase_cold_start (for the full setup/queue/execution/cleanup breakdown), lakeflow_stale_zombie_jobs (if the job turns out to rarely run, queuing may not be worth fixing)
-- caveats: queue_duration_seconds is not populated before late Nov 2025, so on a short-history account it is NULL for every run. runs_queue_null is reported separately so a fully-NULL column degrades to "not assessed - column not yet populated" rather than being read as zero queue time (a NULL is unknown, never "no queue"). queue_duration_seconds lives ONLY on job_run_timeline, not on job_task_run_timeline. It is populated only in the run's end row (runs over 1h are sliced hourly), so this filters to result_state IS NOT NULL. job_id is unique only within a workspace, so all per-job grouping is on (workspace_id, job_id). PERCENTILE_APPROX takes a fraction in [0,1]; 0.95 is correct here. There are no dollars: queue seconds are not a billing unit, and Databricks publishes no DBU-to-dollar rate.
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
       SUM(CASE WHEN queue_duration_seconds IS NULL THEN 1 ELSE 0 END) AS runs_queue_null,
       -- status: worst-first band on p95 queue seconds (field heuristic; :warn_queue_p95_s / :crit_queue_p95_s).
       CASE
         WHEN percentile_approx(queue_duration_seconds, 0.95) IS NULL THEN 'NOT_ASSESSED'
         WHEN percentile_approx(queue_duration_seconds, 0.95) >= :crit_queue_p95_s THEN 'CRITICAL'
         WHEN percentile_approx(queue_duration_seconds, 0.95) >= :warn_queue_p95_s THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM end_rows
GROUP BY workspace_id, job_id
ORDER BY queue_s_p95 DESC
