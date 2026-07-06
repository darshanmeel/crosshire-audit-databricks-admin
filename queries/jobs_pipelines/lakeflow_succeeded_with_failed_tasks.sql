-- query_id: lakeflow_succeeded_with_failed_tasks
-- source: system.lakeflow.job_task_run_timeline (joined to job_run_timeline)
-- feeds: succeeded-with-failures
-- confidence: confirmed
-- caveats: Documented join key: job_task_run_timeline.job_run_id = job_run_timeline.run_id (+ workspace_id). Both tables' result_state populated only in the end row -> filter on both sides.
/* databricks_audit:lakeflow_succeeded_with_failed_tasks */
WITH job_end AS (
  SELECT workspace_id, job_id, run_id AS job_run_id, result_state AS job_result_state
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL
),
task_end AS (
  SELECT workspace_id, job_id, job_run_id, task_key, result_state AS task_result_state
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND result_state IS NOT NULL
)
SELECT j.workspace_id, j.job_id,
       COUNT(DISTINCT j.job_run_id) AS succeeded_runs,
       COUNT(DISTINCT CASE WHEN t.task_result_state IN ('FAILED','ERROR','TIMED_OUT')
                           THEN j.job_run_id END) AS succeeded_runs_with_failed_task
FROM job_end j
LEFT JOIN task_end t
  ON j.workspace_id = t.workspace_id AND j.job_id = t.job_id AND j.job_run_id = t.job_run_id
WHERE j.job_result_state = 'SUCCEEDED'
GROUP BY j.workspace_id, j.job_id
