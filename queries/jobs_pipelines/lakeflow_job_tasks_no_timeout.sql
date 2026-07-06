-- query_id: lakeflow_job_tasks_no_timeout
-- source: system.lakeflow.job_tasks
-- feeds: jobs-no-timeout
-- confidence: confirmed
-- caveats: job_tasks is SCD2 -> latest per (workspace_id, job_id, task_key); task_key unique only within a job. Same not-populated-before-Dec-2025 caveat; tasks_timeout_null exposes the degradation case.
/* databricks_audit:lakeflow_job_tasks_no_timeout */
WITH latest_tasks AS (
  SELECT workspace_id, job_id, task_key, timeout_seconds, delete_time
  FROM system.lakeflow.job_tasks
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id, task_key ORDER BY change_time DESC) = 1
)
SELECT workspace_id,
       COUNT(*) AS active_tasks,
       SUM(CASE WHEN timeout_seconds IS NULL OR timeout_seconds = 0 THEN 1 ELSE 0 END) AS tasks_no_timeout,
       SUM(CASE WHEN timeout_seconds IS NULL THEN 1 ELSE 0 END) AS tasks_timeout_null
FROM latest_tasks
WHERE delete_time IS NULL
GROUP BY workspace_id
