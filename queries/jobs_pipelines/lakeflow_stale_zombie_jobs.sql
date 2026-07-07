-- query_id: lakeflow_stale_zombie_jobs
-- source: system.lakeflow.jobs (joined to job_run_timeline)
-- feeds: stale/zombie jobs
-- confidence: confirmed
-- caveats: jobs is SCD2 -> latest row per (workspace_id, job_id). delete_time IS NULL excludes user-deleted jobs. No incomplete-current-day filter needed (last-seen lookback, not a usage sum).
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID (workspace_id + job_id) over the finding's 30-day lookback window,
--   per-resource (not per run). Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never
--   multiplied. Stale jobs correctly show ~0 net_dbus (no recent runs in the window).
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
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  SELECT u.workspace_id,
         u.usage_metadata.job_id AS job_id,
         SUM(u.usage_quantity)                            AS net_dbus,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.job_id IS NOT NULL
    AND u.usage_date >= date_add(current_date(), -30)
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.job_id
)
SELECT j.workspace_id, j.job_id,
       CASE WHEN j.name IS NULL THEN j.name ELSE concat(substr(j.name, 1, 2), '****') END AS name,
       r.last_run_start,
       CASE WHEN r.last_run_start IS NULL
              OR r.last_run_start < date_add(current_date(), -30)
            THEN 1 ELSE 0 END AS is_stale_30d,
       COALESCE(cr.net_dbus, 0)     AS net_dbus,
       COALESCE(cr.est_usd_list, 0) AS est_usd_list
FROM latest_jobs j
LEFT JOIN last_run r ON j.workspace_id = r.workspace_id AND j.job_id = r.job_id
LEFT JOIN cost_rollup cr ON j.workspace_id = cr.workspace_id AND j.job_id = cr.job_id
WHERE j.delete_time IS NULL