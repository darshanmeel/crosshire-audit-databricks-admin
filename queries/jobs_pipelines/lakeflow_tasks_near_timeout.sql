-- query_id: lakeflow_tasks_near_timeout
-- source: system.lakeflow.job_task_run_timeline JOIN system.lakeflow.job_tasks
-- feeds: Job Health page — retrying / hanging tasks running close to (or past) their timeout (reliability-4)
-- confidence: needs_confirmation
-- caveats: A task "near timeout" = its observed execution_duration_seconds reaches a high fraction (>=80%) of the configured timeout_seconds on the task definition; "over timeout" = it ran >= timeout (a task that should have been killed). BOTH columns are "not populated before late Nov 2025": execution_duration_seconds on job_task_run_timeline, timeout_seconds on job_tasks. We expose tasks_with_timeout / runs_exec_null so missing data degrades to "not assessed", and a NULL/zero timeout is treated as "no bound configured" (NOT a violation and NOT a near-timeout). job_id and task_key are unique only WITHIN a workspace+job -> the join is on (workspace_id, job_id, task_key); job_tasks is SCD2 so we take the latest row per (workspace_id, job_id, task_key) by change_time before joining (avoids fan-out, must-fix). job_task_run_timeline result_state is populated only in the task END row -> filtered to result_state IS NOT NULL. No dollars: durations are not a billing unit.
/* databricks_audit:lakeflow_tasks_near_timeout */
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
       -- runs whose execution reached >= 80% of a CONFIGURED (non-null, >0) timeout
       SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                 AND t.execution_duration_seconds >= 0.8 * lt.timeout_seconds
                THEN 1 ELSE 0 END)                                       AS runs_near_timeout,
       -- runs that ran AT/PAST the configured timeout (should have been killed)
       SUM(CASE WHEN lt.timeout_seconds IS NOT NULL AND lt.timeout_seconds > 0
                 AND t.execution_duration_seconds >= lt.timeout_seconds
                THEN 1 ELSE 0 END)                                       AS runs_over_timeout,
       -- degradation buckets: a NULL/zero timeout is "no bound configured" (not a finding);
       -- a NULL execution duration is "column not yet populated" (not assessed).
       SUM(CASE WHEN lt.timeout_seconds IS NULL OR lt.timeout_seconds = 0
                THEN 1 ELSE 0 END)                                       AS runs_no_task_timeout,
       SUM(CASE WHEN t.execution_duration_seconds IS NULL THEN 1 ELSE 0 END) AS runs_exec_null
FROM task_end t
LEFT JOIN latest_tasks lt
  ON  t.workspace_id = lt.workspace_id
  AND t.job_id       = lt.job_id
  AND t.task_key     = lt.task_key
GROUP BY t.workspace_id, t.job_id, t.task_key, lt.timeout_seconds
