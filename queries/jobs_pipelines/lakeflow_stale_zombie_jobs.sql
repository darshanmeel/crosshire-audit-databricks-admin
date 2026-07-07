-- query_id: lakeflow_stale_zombie_jobs
-- title: Stale / zombie jobs with no recent runs
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.jobs, system.lakeflow.job_run_timeline, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.lakeflow, system.billing; GA
-- params: :stale_days (default 30) days since last run that flags WARN; :crit_stale_days (default 90) days since last run that flags CRITICAL; :period_days (default 30) cost-lookback window for net_dbus/est_usd_list (a separate window from the staleness thresholds)
-- confidence: confirmed
-- confidence_note: the SCD2-latest-row + delete_time filter and the last-run lookback (independent of the cost window) were verified against system.lakeflow.jobs and job_run_timeline in a live workspace.
-- read_this: One row = an active job. The column that matters is last_run_start - the most recent time the job ran, across all history; is_stale flags jobs that have not run in over :stale_days days (or never at all).
-- healthy: last_run_start recent (within :stale_days days) for every active job - field heuristic; tune :stale_days for your account.
-- investigate_if: is_stale = 1, especially where last_run_start is NULL (no run ever recorded) or older than :crit_stale_days days - field heuristic.
-- actions: 1) confirm the job is genuinely unused and pause or delete it (free); 2) if it is meant to run on a longer cadence, document that in the job name/description so it stops looking abandoned (config); 3) n/a - a stale job is not itself a spend decision (it correctly shows ~0 net_dbus, see caveats).
-- next: lakeflow_job_ownership_orphans (stale jobs are often also ownership orphans), lakeflow_health_rule_coverage (a stale job is a low priority for health-rule coverage effort)
-- caveats: jobs is SCD2 - this takes the latest row per (workspace_id, job_id) by change_time; delete_time IS NULL excludes jobs you already deleted. last_run_start looks across ALL history (no lookback window), so no incomplete-current-day filter is needed here. net_dbus is the exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), not your negotiated invoice rate, and it excludes cloud infra/egress cost - treat it as directional. net_dbus/est_usd_list are attributed by (workspace_id, job_id) over the separate :period_days cost-lookback window, pre-aggregated before the LEFT JOIN so rows are never multiplied. A genuinely stale job correctly shows ~0 net_dbus, since it has had no recent runs in that window - net_dbus is not the signal here, staleness is.
-- system.lakeflow.job_run_timeline retains only ~365 days, so last_run_start IS NULL (the 'no run ever recorded' WARN) can equally mean the job last ran beyond that retention window, not that it never ran - treat NULL as 'no run within retention'.
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
    AND u.usage_date >= dateadd(day, -:period_days, current_date())
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.job_id
)
SELECT j.workspace_id, j.job_id,
       CASE WHEN j.name IS NULL THEN j.name ELSE concat(substr(j.name, 1, 2), '****') END AS name,
       r.last_run_start,
       CASE WHEN r.last_run_start IS NULL
              OR r.last_run_start < dateadd(day, -:stale_days, current_date())
            THEN 1 ELSE 0 END AS is_stale,
       COALESCE(cr.net_dbus, 0)     AS net_dbus,
       COALESCE(cr.est_usd_list, 0) AS est_usd_list,
       -- status: worst-first band on days since last run (field heuristic; :stale_days / :crit_stale_days).
       CASE
         WHEN r.last_run_start IS NULL THEN 'WARN'   -- no run ever recorded for this job in job_run_timeline history
         WHEN r.last_run_start < dateadd(day, -:crit_stale_days, current_date()) THEN 'CRITICAL'
         WHEN r.last_run_start < dateadd(day, -:stale_days, current_date()) THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM latest_jobs j
LEFT JOIN last_run r ON j.workspace_id = r.workspace_id AND j.job_id = r.job_id
LEFT JOIN cost_rollup cr ON j.workspace_id = cr.workspace_id AND j.job_id = cr.job_id
WHERE j.delete_time IS NULL
ORDER BY last_run_start ASC
