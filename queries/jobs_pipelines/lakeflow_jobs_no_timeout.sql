-- query_id: lakeflow_jobs_no_timeout
-- title: Jobs with no configured timeout, at-risk DBU exposure
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.jobs, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.lakeflow, system.billing; GA (timeout_seconds was added early Dec 2025)
-- params: :period_days (default 30) cost-lookback window for the flagged-subset DBU/dollar rollup; :warn_no_timeout_jobs (default 5) no-timeout jobs per workspace that flags WARN; :crit_no_timeout_jobs (default 20) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: timeout_seconds is not populated before early Dec 2025; jobs_timeout_null is reported separately so this query degrades to "not assessed" instead of over-claiming "no timeout" on old records - confirm the NULL semantics on your account.
-- read_this: One row = a workspace. The column that matters is jobs_no_timeout - active jobs with no configured (or zero-second) timeout; net_dbus/est_usd_list next to it are the DBUs/list-price dollars attributed to just that flagged subset over the cost-lookback window.
-- healthy: jobs_no_timeout near 0 relative to active_jobs - field heuristic; tune :warn_no_timeout_jobs for your account.
-- investigate_if: jobs_no_timeout at/above :warn_no_timeout_jobs (WARN) or :crit_no_timeout_jobs (CRITICAL), especially where est_usd_list is also high - field heuristic.
-- actions: 1) set an explicit timeout on each flagged job (free); 2) add a default job timeout to your job-creation template or CI job-spec linter (config); 3) n/a - fixing this is free; it prevents future spend from a runaway job rather than requiring new spend.
-- next: lakeflow_job_tasks_no_timeout (the task-level version of this same gap), lakeflow_stale_zombie_jobs (a no-timeout job that also never runs is lower priority)
-- caveats: timeout_seconds is not populated before early Dec 2025, so a NULL is ambiguous (no timeout vs not-yet-populated); jobs_timeout_null is reported separately so this query degrades to "not assessed - column not yet populated" rather than over-claiming "no timeout" on old records. net_dbus is the exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), not your negotiated invoice rate, and it excludes cloud infra/egress cost - treat it as directional. Cost is attributed by (workspace_id, usage_metadata.job_id) over the window (per-job), not per run/event; the rollup is pre-aggregated then LEFT JOINed 1:1 to the deduped job set, so result rows are never multiplied. This query is an aggregate per-workspace COUNT with no time window of its own (a current-state snapshot); net_dbus/est_usd_list attribute DBUs/dollars ONLY to the flagged subset (jobs with no timeout) over the configurable cost-lookback window :period_days - that window affects only the added cost columns, never the counts, filters, joins, or grain.
-- One-time SUBMIT_RUN/WORKFLOW_RUN executions never write to system.lakeflow.jobs, so runaway ephemeral or submit-run workloads (a prime no-timeout risk) are entirely invisible to this inventory and undercount the true no-timeout exposure.
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
  -- so the LEFT JOIN below to the deduped job set is strictly 1:1 and cannot fan out.
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
       -- cost visibility: DBUs / list-price $ attributed to the flagged subset only
       -- (jobs with no timeout: timeout_seconds IS NULL OR = 0), summed over qualifying jobs.
       SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0
                THEN COALESCE(cr.net_dbus, 0) ELSE 0 END)     AS net_dbus,
       SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0
                THEN COALESCE(cr.est_usd_list, 0) ELSE 0 END) AS est_usd_list,
       -- status: worst-first band on no-timeout job count (field heuristic; :warn_no_timeout_jobs / :crit_no_timeout_jobs).
       CASE
         WHEN SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0 THEN 1 ELSE 0 END) >= :crit_no_timeout_jobs THEN 'CRITICAL'
         WHEN SUM(CASE WHEN lj.timeout_seconds IS NULL OR lj.timeout_seconds = 0 THEN 1 ELSE 0 END) >= :warn_no_timeout_jobs THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM latest_jobs lj
LEFT JOIN cost_rollup cr
  ON lj.workspace_id = cr.workspace_id AND lj.job_id = cr.job_id
WHERE lj.delete_time IS NULL
GROUP BY lj.workspace_id
ORDER BY jobs_no_timeout DESC
