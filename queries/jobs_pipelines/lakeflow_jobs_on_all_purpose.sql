-- query_id: lakeflow_jobs_on_all_purpose
-- source: system.lakeflow.job_task_run_timeline (joined cross-domain to system.compute.clusters)
-- feeds: jobs-on-all-purpose
-- confidence: needs_confirmation — verifier status `ok` on columns; self-flagged because the join is cross-domain and compute_ids may be unpopulated on old rows.
-- NEEDS WORKSPACE CONFIRMATION: the cross-domain join and compute_ids population. compute_ids is confirmed in lakeflow; system.compute.clusters.cluster_source/cluster_id/change_time are confirmed in the COMPUTE doc, so columns pass — but confirm on the target workspace (and that compute_ids is populated on old rows).
-- caveats: Anti-pattern = job task running on cluster_source IN ('UI','API') (all-purpose). EXPLODE(compute_ids) drops rows where compute_ids is NULL/empty — those (early-Dec-2025 caveat) should be reported as a separate "not assessed" bucket, not implicitly zero. Confirm cluster_source exact name + value enum and that clusters is SCD2 on the workspace.
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing cluster_id over the 30-day window (per-resource), not per task/run. Cost
--   rollup is pre-aggregated per (workspace_id, cluster_id) then LEFT JOINed, so finding rows are never
--   multiplied. A shared all-purpose cluster serving multiple jobs shows its FULL cluster DBUs on each
--   job row (billing has no clean per-job split of an interactive cluster's cost).
/* databricks_audit:lakeflow_jobs_on_all_purpose */
WITH task_compute AS (
  SELECT workspace_id, job_id, run_id, task_key, EXPLODE(compute_ids) AS compute_id
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL
    AND compute_ids IS NOT NULL
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Pre-aggregated cost per all-purpose cluster over the SAME 30-day window as the finding.
  SELECT u.workspace_id,
         u.usage_metadata.cluster_id                      AS cluster_id,
         SUM(u.usage_quantity)                            AS net_dbus,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.cluster_id IS NOT NULL
    AND u.usage_date >= date_add(current_date(), -30)
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.cluster_id
)
SELECT tc.workspace_id, tc.job_id, tc.compute_id, c.cluster_source,
       COUNT(DISTINCT tc.run_id) AS task_runs,
       -- cost is constant within each (workspace_id, compute_id) group -> MAX() surfaces the single value
       COALESCE(MAX(cr.net_dbus), 0)     AS net_dbus,
       COALESCE(MAX(cr.est_usd_list), 0) AS est_usd_list
FROM task_compute tc
LEFT JOIN (
  SELECT workspace_id, cluster_id, cluster_source
  FROM system.compute.clusters
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, cluster_id ORDER BY change_time DESC) = 1
) c
  ON tc.workspace_id = c.workspace_id AND tc.compute_id = c.cluster_id
LEFT JOIN cost_rollup cr
  ON tc.workspace_id = cr.workspace_id AND tc.compute_id = cr.cluster_id
GROUP BY tc.workspace_id, tc.job_id, tc.compute_id, c.cluster_source