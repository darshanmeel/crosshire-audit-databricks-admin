-- query_id: lakeflow_job_tasks_no_timeout
-- title: Job tasks with no configured timeout, at-risk DBU exposure
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.job_tasks, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.lakeflow, system.billing; GA (job_tasks.timeout_seconds was added late Nov 2025)
-- params: :period_days (default 30) billing look-back window for the cost rollup only (does not change this query's grain/filters/counts); :warn_no_timeout_tasks (default 5) no-timeout tasks per workspace that flags WARN; :crit_no_timeout_tasks (default 20) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: timeout_seconds is not populated before late Nov 2025; tasks_timeout_null exposes that so a short-history account degrades instead of reading NULL as "no timeout". net_dbus/est_usd_list here are an upper-bound exposure figure, not the exact cost of the untimed tasks - see caveats.
-- read_this: One row = a workspace. The column that matters is tasks_no_timeout - active tasks with no configured (or zero-second) timeout; net_dbus/est_usd_list next to it are the at-risk DBUs of any job that contains at least one such task.
-- healthy: tasks_no_timeout near 0 relative to active_tasks - field heuristic; tune :warn_no_timeout_tasks for your account.
-- investigate_if: tasks_no_timeout at/above :warn_no_timeout_tasks (WARN) or :crit_no_timeout_tasks (CRITICAL) - field heuristic.
-- actions: 1) list the flagged tasks and set an explicit timeout on each in the job UI/API (free); 2) add a default task timeout to your job-creation template or CI job-spec linter (config); 3) n/a - fixing this is free; it prevents future spend rather than requiring new spend.
-- next: lakeflow_jobs_no_timeout (the job-level version of this same gap), lakeflow_tasks_near_timeout (for tasks that DO have a timeout but are running close to it)
-- caveats: job_tasks is SCD2, so this takes the latest row per (workspace_id, job_id, task_key) by change_time; task_key is unique only within a job. The same not-populated-before-late-Nov-2025 caveat applies to timeout_seconds; tasks_timeout_null exposes the degradation case. net_dbus is the exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), not your negotiated invoice rate, and it excludes cloud infra/egress cost - treat it as directional. Cost is attributed by (workspace_id, job_id) over the window, not per event/request; the rollup is pre-aggregated then LEFT JOINed, so result rows are never multiplied. ATTRIBUTION CAVEAT: this query counts TASKS, but system.billing.usage exposes only job_id (no task_key), so DBUs cannot be split per task. net_dbus/est_usd_list here are the AT-RISK subset: total DBUs of jobs that contain at least one no-timeout task, summed to workspace grain. A qualifying job's cost includes any of its tasks that DO have a timeout, so this over-attributes - treat it as an upper bound on the exposure, not the exact cost of the untimed tasks. WINDOW: this query itself is a point-in-time state check with no period; :period_days only sets the billing look-back for the cost rollup.
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
       COALESCE(rjc.est_usd_at_risk, 0) AS est_usd_list,
       -- status: worst-first band on no-timeout task count (field heuristic; :warn_no_timeout_tasks / :crit_no_timeout_tasks).
       CASE
         WHEN SUM(CASE WHEN lt.timeout_seconds IS NULL OR lt.timeout_seconds = 0 THEN 1 ELSE 0 END) >= :crit_no_timeout_tasks THEN 'CRITICAL'
         WHEN SUM(CASE WHEN lt.timeout_seconds IS NULL OR lt.timeout_seconds = 0 THEN 1 ELSE 0 END) >= :warn_no_timeout_tasks THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM latest_tasks lt
LEFT JOIN risk_job_cost rjc ON rjc.workspace_id = lt.workspace_id
WHERE lt.delete_time IS NULL
GROUP BY lt.workspace_id, rjc.dbus_at_risk, rjc.est_usd_at_risk
ORDER BY tasks_no_timeout DESC
