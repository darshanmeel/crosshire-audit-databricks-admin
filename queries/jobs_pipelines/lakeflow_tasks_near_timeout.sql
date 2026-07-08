-- query_id: lakeflow_tasks_near_timeout
-- title: Tasks running near or past their configured timeout
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.job_task_run_timeline, system.lakeflow.job_tasks
-- requires: SELECT on system.lakeflow; GA (execution_duration_seconds and timeout_seconds were both added late Nov 2025)
-- empty_if: schema_not_enabled, submit_run_skipped
-- params: :period_days (default 30) rolling window in days; :near_timeout_ratio (default 0.8) fraction of the configured timeout that counts as "near timeout"; :warn_near_timeout_runs (default 3) near/over-timeout runs for a task that flags WARN; :crit_near_timeout_runs (default 10) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: both execution_duration_seconds (job_task_run_timeline) and timeout_seconds (job_tasks) are not populated before late Nov 2025; runs_no_task_timeout / runs_exec_null expose that so a short-history account degrades to "not assessed" instead of reading a missing value as zero.
-- read_this: One row = a task within a job. The columns that matter are runs_near_timeout (execution reached at/above :near_timeout_ratio of the configured timeout) and runs_over_timeout (execution reached or passed the timeout and should have been killed).
-- healthy: runs_near_timeout and runs_over_timeout both at/near 0 - field heuristic; tune :near_timeout_ratio and :warn_near_timeout_runs for your account.
-- investigate_if: (runs_near_timeout + runs_over_timeout) at/above :warn_near_timeout_runs (WARN) or :crit_near_timeout_runs (CRITICAL) - field heuristic; runs_over_timeout > 0 is the more urgent signal since the task should already have been killed.
-- actions: 1) look at whether the task's input volume grew and the timeout was never revisited (free); 2) raise the task's configured timeout to a realistic value, or split the task into smaller steps (config); 3) if the task is legitimately compute-bound, give it a faster node type or more parallelism (spend).
-- next: lakeflow_job_tasks_no_timeout (the tasks with no timeout at all, a related gap), lakeflow_phase_cold_start (for the run-level setup/queue/execution breakdown)
-- caveats: "Near timeout" means observed execution_duration_seconds reaches :near_timeout_ratio of the task's configured timeout_seconds; "over timeout" means it ran at/past the timeout. Both source columns are not populated before late Nov 2025 - runs_no_task_timeout / runs_exec_null are reported separately so missing data degrades to "not assessed" rather than a false positive, and a NULL/zero timeout is treated as "no bound configured" (not a violation and not a near-timeout). job_id and task_key are unique only within a workspace+job, so the join is on (workspace_id, job_id, task_key); job_tasks is SCD2, so this takes the latest row per (workspace_id, job_id, task_key) by change_time before joining, to avoid fan-out. job_task_run_timeline's result_state is populated only in the task's end row, so this filters to result_state IS NOT NULL. There are no dollars here - durations are not a billing unit.
WITH latest_tasks AS (
  SELECT workspace_id, job_id, task_key, timeout_seconds, delete_time
  FROM system.lakeflow.job_tasks
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY workspace_id, job_id, task_key ORDER BY change_time DESC
  ) = 1
),
task_end AS (
  SELECT workspace_id, job_id, task_key, run_id, execution_duration_seconds
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= dateadd(day, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())   -- drop incomplete current day
    AND result_state IS NOT NULL                                   -- task end row only
)
SELECT t.workspace_id, t.job_id, t.task_key,
       lt.timeout_seconds,
       COUNT(DISTINCT t.run_id)                                          AS task_runs,
       MAX(t.execution_duration_seconds)                                 AS max_exec_s,
       percentile_approx(t.execution_duration_seconds, 0.95)            AS exec_s_p95,
       -- runs whose execution reached >= :near_timeout_ratio of a CONFIGURED (non-null, >0) timeout
       SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                 AND t.execution_duration_seconds >= :near_timeout_ratio * lt.timeout_seconds
                THEN 1 ELSE 0 END)                                       AS runs_near_timeout,
       -- runs that ran AT/PAST the configured timeout (should have been killed)
       SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                 AND t.execution_duration_seconds >= lt.timeout_seconds
                THEN 1 ELSE 0 END)                                       AS runs_over_timeout,
       -- degradation buckets: a NULL/zero timeout is "no bound configured" (not a finding);
       -- a NULL execution duration is "column not yet populated" (not assessed).
       SUM(CASE WHEN lt.timeout_seconds IS NULL OR lt.timeout_seconds = 0
                THEN 1 ELSE 0 END)                                       AS runs_no_task_timeout,
       SUM(CASE WHEN t.execution_duration_seconds IS NULL THEN 1 ELSE 0 END) AS runs_exec_null,
       -- status: worst-first band on near/over-timeout run count (field heuristic;
       -- :warn_near_timeout_runs / :crit_near_timeout_runs).
       CASE
         WHEN (SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                    AND t.execution_duration_seconds >= :near_timeout_ratio * lt.timeout_seconds THEN 1 ELSE 0 END)
             + SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                    AND t.execution_duration_seconds >= lt.timeout_seconds THEN 1 ELSE 0 END)) >= :crit_near_timeout_runs THEN 'CRITICAL'
         WHEN (SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                    AND t.execution_duration_seconds >= :near_timeout_ratio * lt.timeout_seconds THEN 1 ELSE 0 END)
             + SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                    AND t.execution_duration_seconds >= lt.timeout_seconds THEN 1 ELSE 0 END)) >= :warn_near_timeout_runs THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM task_end t
LEFT JOIN latest_tasks lt
  ON  t.workspace_id = lt.workspace_id
  AND t.job_id       = lt.job_id
  AND t.task_key     = lt.task_key
GROUP BY t.workspace_id, t.job_id, t.task_key, lt.timeout_seconds
ORDER BY (runs_near_timeout + runs_over_timeout) DESC
