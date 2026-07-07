-- query_id: lakeflow_jobs_no_timeout
-- source: system.lakeflow.jobs
-- feeds: jobs-no-timeout; stale/zombie jobs
-- confidence: confirmed
-- caveats: timeout_seconds is "not populated before early Dec 2025" -> a NULL is ambiguous (no timeout vs not-yet-populated). jobs_timeout_null is reported separately so the finding degrades to "not assessed — column not yet populated" rather than over-claiming "no timeout" on old records (confirm the NULL semantics — see checklist).
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID (workspace_id + usage_metadata.job_id) over the window (per-job),
--   not per run/event. Cost rollup is pre-aggregated then LEFT JOINed 1:1 to the deduped job set, so
--   finding rows are never multiplied.
-- This finding is an aggregate per-workspace COUNT with no time window (current-state snapshot), so
--   net_dbus/est_usd_list attribute DBUs/$ ONLY to the flagged subset (jobs with no timeout) over a
--   configurable cost-lookback window :period_days (recommend 30). Adding this param affects only the
--   added cost columns; it does not change any existing count, filter, join, or grain.
/* databricks_audit:lakeflow_jobs_no_timeout */
WITH latest_jobs AS (
  SELECT workspace_id, job_id, name, timeout_seconds, paused, delete_time, create_time
  FROM system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Per (workspace_id, job_id) DBUs + list-price $ over the cost-lookback window. job_id is NOT
  -- globally unique -> keyed on workspace_id + job_id. Pre-aggregated (1 row per workspace_id+job_id)
  -- so the downstream LEFT JOIN to the deduped job set is strictly 1:1 and cannot fan out.
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
    AND u.usage_date >= date_sub(current_date(), :period_days)
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.job_id
)
SELECT lj.workspace_id,
       COUNT(*) AS active_jobs,
       SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0 THEN 1 ELSE 0 END) AS jobs_no_timeout,
       SUM(CASE WHEN lj.timeout_seconds IS NULL THEN 1 ELSE 0 END) AS jobs_timeout_null,
       SUM(CASE WHEN lj.create_time     IS NULL THEN 1 ELSE 0 END) AS jobs_create_time_null,
       -- ADDED cost visibility: DBUs / list-price $ attributed to the flagged subset only
       -- (jobs with no timeout: timeout_seconds IS NULL OR = 0), summed over qualifying jobs.
       SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0
                THEN COALESCE(cr.net_dbus, 0) ELSE 0 END)     AS net_dbus,
       SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0
                THEN COALESCE(cr.est_usd_list, 0) ELSE 0 END) AS est_usd_list
FROM latest_jobs lj
LEFT JOIN cost_rollup cr
  ON lj.workspace_id = cr.workspace_id AND lj.job_id = cr.job_id
WHERE lj.delete_time IS NULL
GROUP BY lj.workspace_id