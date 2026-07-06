-- query_id: lakeflow_jobs_no_timeout
-- source: system.lakeflow.jobs
-- feeds: jobs-no-timeout; stale/zombie jobs
-- confidence: confirmed
-- caveats: timeout_seconds is "not populated before early Dec 2025" -> a NULL is ambiguous (no timeout vs not-yet-populated). jobs_timeout_null is reported separately so the finding degrades to "not assessed — column not yet populated" rather than over-claiming "no timeout" on old records (confirm the NULL semantics — see checklist).
/* databricks_audit:lakeflow_jobs_no_timeout */
WITH latest_jobs AS (
  SELECT workspace_id, job_id, name, timeout_seconds, paused, delete_time, create_time
  FROM system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1
)
SELECT workspace_id,
       COUNT(*) AS active_jobs,
       SUM(CASE WHEN timeout_seconds IS NULL OR timeout_seconds = 0 THEN 1 ELSE 0 END) AS jobs_no_timeout,
       SUM(CASE WHEN timeout_seconds IS NULL THEN 1 ELSE 0 END) AS jobs_timeout_null,
       SUM(CASE WHEN create_time     IS NULL THEN 1 ELSE 0 END) AS jobs_create_time_null
FROM latest_jobs
WHERE delete_time IS NULL
GROUP BY workspace_id
