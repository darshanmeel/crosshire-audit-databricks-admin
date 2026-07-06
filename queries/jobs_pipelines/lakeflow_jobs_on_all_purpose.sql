-- query_id: lakeflow_jobs_on_all_purpose
-- source: system.lakeflow.job_task_run_timeline (joined cross-domain to system.compute.clusters)
-- feeds: jobs-on-all-purpose
-- confidence: needs_confirmation — verifier status `ok` on columns; self-flagged because the join is cross-domain and compute_ids may be unpopulated on old rows.
-- NEEDS WORKSPACE CONFIRMATION: the cross-domain join and compute_ids population. compute_ids is confirmed in lakeflow; system.compute.clusters.cluster_source/cluster_id/change_time are confirmed in the COMPUTE doc, so columns pass — but confirm on the target workspace (and that compute_ids is populated on old rows).
-- caveats: Anti-pattern = job task running on cluster_source IN ('UI','API') (all-purpose). EXPLODE(compute_ids) drops rows where compute_ids is NULL/empty — those (early-Dec-2025 caveat) should be reported as a separate "not assessed" bucket, not implicitly zero. Confirm cluster_source exact name + value enum and that clusters is SCD2 on the workspace.
/* databricks_audit:lakeflow_jobs_on_all_purpose */
WITH task_compute AS (
  SELECT workspace_id, job_id, run_id, task_key, EXPLODE(compute_ids) AS compute_id
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL
    AND compute_ids IS NOT NULL
)
SELECT tc.workspace_id, tc.job_id, tc.compute_id, c.cluster_source,
       COUNT(DISTINCT tc.run_id) AS task_runs
FROM task_compute tc
LEFT JOIN (
  SELECT workspace_id, cluster_id, cluster_source
  FROM system.compute.clusters
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, cluster_id ORDER BY change_time DESC) = 1
) c
  ON tc.workspace_id = c.workspace_id AND tc.compute_id = c.cluster_id
GROUP BY tc.workspace_id, tc.job_id, tc.compute_id, c.cluster_source
