-- query_id: lakeflow_retries_repairs
-- source: system.lakeflow.job_run_timeline
-- feeds: retries/repairs
-- confidence: confirmed
-- caveats: Retries = (non-NULL-result_state rows per run_id) - 1, per the documented visibility caveat. Must filter to end rows first so a single long run's intermediate hourly slices aren't miscounted as retries.
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID (workspace_id + job_id) over the window (per-job), not per run/retry.
--   Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never multiplied.
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
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  -- Pre-aggregated cost per (workspace_id, job_id). job_id is not globally unique, so we key on
  -- workspace_id + job_id. Window mirrors the finding's trailing-30-day bound via usage_date.
  SELECT u.workspace_id,
         u.usage_metadata.job_id                          AS job_id,
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
SELECT pr.workspace_id, pr.job_id,
       COUNT(*)             AS distinct_runs,
       SUM(pr.attempt_rows)    AS total_attempt_rows,
       SUM(pr.attempt_rows - 1) AS total_retries,
       SUM(CASE WHEN pr.attempt_rows > 1 THEN 1 ELSE 0 END) AS runs_with_retry,
       COALESCE(MAX(cr.net_dbus), 0)     AS net_dbus,
       COALESCE(MAX(cr.est_usd_list), 0) AS est_usd_list
FROM per_run pr
LEFT JOIN cost_rollup cr
  ON pr.workspace_id = cr.workspace_id AND pr.job_id = cr.job_id
GROUP BY pr.workspace_id, pr.job_id