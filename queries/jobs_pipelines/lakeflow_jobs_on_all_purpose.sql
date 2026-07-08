-- query_id: lakeflow_jobs_on_all_purpose
-- title: Jobs running on all-purpose (interactive) clusters
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.job_task_run_timeline, system.compute.clusters, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.lakeflow, system.compute, system.billing; GA
-- empty_if: schema_not_enabled
-- params: :period_days (default 30) rolling window in days; :crit_share_usd (default 100) naive per-job list-$ share on an all-purpose cluster that flags CRITICAL; :top_n (default 500) row cap
-- confidence: needs_confirmation
-- confidence_note: The cross-domain join to system.compute.clusters and whether compute_ids is populated on older rows are the two things to confirm on your own workspace.
-- read_this: One row = one (job, all-purpose cluster) placement over the window. cluster_source is the column that matters - UI or API means the job ran on an interactive/all-purpose cluster (the anti-pattern) instead of a cheaper jobs cluster. est_usd_list_share is a naive even split of the shared cluster's list-price cost across the jobs on it.
-- healthy: cluster_source = JOB, i.e. the task ran on dedicated jobs compute - est_usd_list_share is then informational only (field heuristic).
-- investigate_if: cluster_source IN ('UI','API') (WARN), especially with est_usd_list_share at/above :crit_share_usd (CRITICAL) - a job pinned to an always-on interactive cluster (field heuristic). The trailing NOT_ASSESSED summary row counts runs dropped for null compute_ids; do not read those as "clean".
-- actions: 1) point the job at a job cluster / new-cluster-per-run instead of an existing all-purpose cluster (free, in the job definition); 2) if the interactive cluster exists only to serve jobs, add auto-termination or delete it (config); 3) if shared interactive compute is genuinely required, move the heavy jobs to a right-sized jobs cluster (spend / reshape).
-- next: cost_by_job (to dollarize the same jobs' DBUs), lakeflow_failed_jobs_wasted_dbus (if these jobs also fail), compute_warehouse_idle_gaps (if the shared cluster sits idle between runs)
-- caveats: Anti-pattern = a job task running on cluster_source IN ('UI','API') (all-purpose). EXPLODE(compute_ids) drops rows where compute_ids is NULL/empty (e.g. early-Dec-2025 rows) - those are surfaced as a separate NOT_ASSESSED summary row (task_runs = dropped runs), NEVER implicitly counted as zero or as clean. Confirm the exact cluster_source column name and value enum, and that system.compute.clusters is SCD2 on your workspace (the latest row is taken by change_time). net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), NOT the negotiated invoice rate, and excludes cloud infra/egress $. Cost is attributed by billing cluster_id over the window (per-resource, not per task/run), pre-aggregated per (workspace_id, cluster_id) then LEFT JOINed so rows are never multiplied. A shared all-purpose cluster serving multiple jobs shows its FULL cluster DBUs on each job row (billing has no clean per-job split of an interactive cluster's cost); est_usd_list_share divides that full cost by jobs_sharing_cluster (distinct jobs on the cluster) as a NAIVE even split - it is not a metered per-job figure.
WITH task_compute AS (
  SELECT workspace_id, job_id, run_id, task_key, EXPLODE(compute_ids) AS compute_id
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= dateadd(DAY, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL
    AND compute_ids IS NOT NULL
),
-- Runs dropped because compute_ids was NULL/empty -> reported as NOT_ASSESSED, never as zero.
dropped AS (
  SELECT workspace_id, COUNT(DISTINCT run_id) AS dropped_runs
  FROM system.lakeflow.job_task_run_timeline
  WHERE period_start_time >= dateadd(DAY, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL
    AND compute_ids IS NULL
  GROUP BY workspace_id
),
-- distinct jobs sharing each cluster in the window (denominator for the naive split).
cluster_jobs AS (
  SELECT workspace_id, compute_id, COUNT(DISTINCT job_id) AS jobs_sharing_cluster
  FROM task_compute
  GROUP BY workspace_id, compute_id
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Pre-aggregated cost per all-purpose cluster over the SAME window as the finding.
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
    AND u.usage_date >= dateadd(DAY, -:period_days, current_date())
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.cluster_id
),
finding AS (
  SELECT tc.workspace_id,
         CAST(tc.job_id AS STRING)         AS job_id,
         CAST(tc.compute_id AS STRING)     AS compute_id,
         c.cluster_source,
         COUNT(DISTINCT tc.run_id)          AS task_runs,
         COALESCE(MAX(cr.net_dbus), 0)      AS net_dbus,
         COALESCE(MAX(cr.est_usd_list), 0)  AS est_usd_list,
         MAX(cj.jobs_sharing_cluster)       AS jobs_sharing_cluster
  FROM task_compute tc
  LEFT JOIN (
    SELECT workspace_id, cluster_id, cluster_source
    FROM system.compute.clusters
    QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, cluster_id ORDER BY change_time DESC) = 1
  ) c
    ON tc.workspace_id = c.workspace_id AND tc.compute_id = c.cluster_id
  LEFT JOIN cost_rollup cr
    ON tc.workspace_id = cr.workspace_id AND tc.compute_id = cr.cluster_id
  LEFT JOIN cluster_jobs cj
    ON tc.workspace_id = cj.workspace_id AND tc.compute_id = cj.compute_id
  GROUP BY tc.workspace_id, tc.job_id, tc.compute_id, c.cluster_source
)
SELECT
  workspace_id, job_id, compute_id, cluster_source, task_runs,
  net_dbus, est_usd_list, jobs_sharing_cluster,
  -- naive even split of the shared cluster's list-price cost across the jobs on it.
  est_usd_list / NULLIF(jobs_sharing_cluster, 0)                        AS est_usd_list_share,
  CASE
    WHEN cluster_source IS NULL THEN 'NOT_ASSESSED'
    WHEN cluster_source IN ('UI', 'API')
         AND est_usd_list / NULLIF(jobs_sharing_cluster, 0) >= :crit_share_usd THEN 'CRITICAL'
    WHEN cluster_source IN ('UI', 'API') THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM finding
UNION ALL
SELECT
  workspace_id,
  CAST(NULL AS STRING)                       AS job_id,
  CAST(NULL AS STRING)                       AS compute_id,
  'null compute_ids'                         AS cluster_source,
  dropped_runs                               AS task_runs,
  CAST(NULL AS DOUBLE)                       AS net_dbus,
  CAST(NULL AS DOUBLE)                       AS est_usd_list,
  CAST(NULL AS BIGINT)                       AS jobs_sharing_cluster,
  CAST(NULL AS DOUBLE)                       AS est_usd_list_share,
  'NOT_ASSESSED'                             AS status
FROM dropped
ORDER BY est_usd_list_share DESC
LIMIT :top_n
