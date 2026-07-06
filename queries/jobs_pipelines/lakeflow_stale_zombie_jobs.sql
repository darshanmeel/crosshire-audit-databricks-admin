-- query_id: lakeflow_stale_zombie_jobs
-- source: system.lakeflow.jobs (joined to job_run_timeline)
-- feeds: stale/zombie jobs
-- confidence: confirmed
-- caveats: jobs is SCD2 -> latest row per (workspace_id, job_id). delete_time IS NULL excludes user-deleted jobs. No incomplete-current-day filter needed (last-seen lookback, not a usage sum).
/* databricks_audit:lakeflow_stale_zombie_jobs */
WITH latest_jobs AS (
  SELECT workspace_id, job_id, name, run_as, creator_id, delete_time
  FROM system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1
),
last_run AS (
  SELECT workspace_id, job_id, MAX(period_start_time) AS last_run_start
  FROM system.lakeflow.job_run_timeline
  GROUP BY workspace_id, job_id
)
SELECT j.workspace_id, j.job_id,
       CASE WHEN j.name IS NULL THEN j.name ELSE concat(substr(j.name, 1, 2), '****') END AS name,
       r.last_run_start,
       CASE WHEN r.last_run_start IS NULL
              OR r.last_run_start < date_add(current_date(), -30)
            THEN 1 ELSE 0 END AS is_stale_30d
FROM latest_jobs j
LEFT JOIN last_run r ON j.workspace_id = r.workspace_id AND j.job_id = r.job_id
WHERE j.delete_time IS NULL
