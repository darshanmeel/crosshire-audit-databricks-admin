-- query_id: lakeflow_job_tasks_no_timeout
-- source: system.lakeflow.job_tasks
-- feeds: jobs-no-timeout
-- confidence: confirmed
-- caveats: job_tasks is SCD2 -> latest per (workspace_id, job_id, task_key); task_key unique only within a job. Same not-populated-before-Dec-2025 caveat; tasks_timeout_null exposes the degradation case.
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID over the window (per workspace_id + job_id), not per event/request.
--   Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never multiplied.
-- ATTRIBUTION CAVEAT: this finding counts TASKS, but system.billing.usage exposes only job_id (no
--   task_key), so DBUs cannot be split per task. net_dbus/est_usd_list here are the AT-RISK subset:
--   total DBUs of jobs that contain >=1 no-timeout task, summed to workspace grain. A qualifying job's
--   cost includes any of its tasks that DO have a timeout, so this over-attributes -- treat as an upper
--   bound on the exposure, not the exact cost of the untimed tasks.
-- WINDOW: the finding is a point-in-time state check with no period; :period_days sets the billing
--   look-back for the cost rollup only (does not change the finding's grain/filters/counts).
/* databricks_audit:lakeflow_job_tasks_no_timeout */
WITH latest_tasks AS (
  SELECT workspace_id, job_id, task_key, timeout_seconds, delete_time
  FROM system.lakeflow.job_tasks
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id, task_key ORDER BY change_time DESC) = 1
),
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
-- Pre-aggregated cost per (workspace_id, job_id) over the billing look-back window.
cost_rollup AS (
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
    AND u.usage_date >= date_add(current_date(), -:period_days)
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.job_id
),
-- Jobs that have >=1 active no-timeout task, with their at-risk cost summed to workspace grain (1 row/ws).
risk_job_cost AS (
  SELECT rj.workspace_id,
         SUM(COALESCE(cr.net_dbus, 0))     AS dbus_at_risk,
         SUM(COALESCE(cr.est_usd_list, 0)) AS est_usd_at_risk
  FROM (
    SELECT DISTINCT workspace_id, job_id
    FROM latest_tasks
    WHERE delete_time IS NULL
      AND (timeout_seconds IS NULL OR timeout_seconds = 0)
  ) rj
  LEFT JOIN cost_rollup cr
    ON cr.workspace_id = rj.workspace_id AND cr.job_id = rj.job_id
  GROUP BY rj.workspace_id
)
SELECT lt.workspace_id,
       COUNT(*) AS active_tasks,
       SUM(CASE WHEN lt.timeout_seconds IS NULL OR lt.timeout_seconds = 0 THEN 1 ELSE 0 END) AS tasks_no_timeout,
       SUM(CASE WHEN lt.timeout_seconds IS NULL THEN 1 ELSE 0 END) AS tasks_timeout_null,
       COALESCE(rjc.dbus_at_risk, 0)    AS net_dbus,
       COALESCE(rjc.est_usd_at_risk, 0) AS est_usd_list
FROM latest_tasks lt
LEFT JOIN risk_job_cost rjc ON rjc.workspace_id = lt.workspace_id
WHERE lt.delete_time IS NULL
GROUP BY lt.workspace_id, rjc.dbus_at_risk, rjc.est_usd_at_risk