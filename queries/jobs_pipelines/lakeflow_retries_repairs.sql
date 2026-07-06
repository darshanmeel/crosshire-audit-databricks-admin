-- query_id: lakeflow_retries_repairs
-- source: system.lakeflow.job_run_timeline
-- feeds: retries/repairs
-- confidence: confirmed
-- caveats: Retries = (non-NULL-result_state rows per run_id) - 1, per the documented visibility caveat. Must filter to end rows first so a single long run's intermediate hourly slices aren't miscounted as retries.
/* databricks_audit:lakeflow_retries_repairs */
WITH end_rows AS (
  SELECT workspace_id, job_id, run_id
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL          -- one non-NULL result_state row per attempt
),
per_run AS (
  SELECT workspace_id, job_id, run_id, COUNT(*) AS attempt_rows
  FROM end_rows GROUP BY workspace_id, job_id, run_id
)
SELECT workspace_id, job_id,
       COUNT(*)             AS distinct_runs,
       SUM(attempt_rows)    AS total_attempt_rows,
       SUM(attempt_rows - 1) AS total_retries,
       SUM(CASE WHEN attempt_rows > 1 THEN 1 ELSE 0 END) AS runs_with_retry
FROM per_run
GROUP BY workspace_id, job_id
