-- query_id: lakeflow_failed_jobs_wasted_dbus
-- title: Failed jobs ranked by wasted DBUs
-- domain: jobs_pipelines   tier: deep
-- reads: system.lakeflow.job_run_timeline, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.lakeflow, system.billing; GA (job_run_timeline and billing.usage/list_prices are generally available)
-- empty_if: schema_not_enabled
-- params: :period_days (default 30) rolling window in days; :warn_failed_runs (default 3) failed runs for a job in the window that flags WARN; :crit_failed_runs (default 10) failed runs that flags CRITICAL; :warn_wasted_dbus (default 10) wasted-DBU proxy that flags WARN; :crit_wasted_dbus (default 50) wasted-DBU proxy that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: usage_metadata carries job_id but not run_id, so wasted DBUs are apportioned across the job by failed-run share rather than measured per failed run; job_id is also unique only within a workspace, so every join here keys on (workspace_id, job_id).
-- read_this: One row = a job with at least one failed run in the window. The column that matters is wasted_dbus_proxy - the job's net DBUs scaled by the share of its runs that failed; est_usd_list turns that into a rough list-price dollar figure. last_failed_termination_code tells you why the most recent failure happened.
-- healthy: few failed_runs and a low wasted_dbus_proxy relative to :warn_wasted_dbus - field heuristic; tune :warn_failed_runs/:warn_wasted_dbus for your account.
-- investigate_if: failed_runs at/above :warn_failed_runs or wasted_dbus_proxy at/above :warn_wasted_dbus (WARN); either at/above :crit_failed_runs / :crit_wasted_dbus (CRITICAL) - field heuristic.
-- actions: 1) read last_failed_termination_code and fix the root cause in the job code or config (free); 2) add a retry cap or failure alert so a broken job stops burning DBUs unnoticed (config); 3) if the job needs more headroom (timeouts, cluster sizing) to stop failing, resize its cluster (spend).
-- next: lakeflow_termination_taxonomy (for the org-wide termination_code breakdown), lakeflow_retries_repairs (to see how many attempts each failing run actually took)
-- caveats: Wasted DBUs = the net DBUs billed on usage rows whose usage_metadata.job_id ran a FAILED/ERROR/TIMED_OUT job-run in the window. Because usage_metadata carries job_id but not run_id, DBUs attribute to the whole job, not the individual failed run - a job that mostly succeeds will show an over-attributed proxy, so read wasted_dbus_proxy as a proxy, never as exact run-level waste. job_id is unique only within a workspace, so the usage-to-run join is always on (workspace_id, job_id), never job_id alone. usage_quantity is summed across all record_types (ORIGINAL/RETRACTION/RESTATEMENT already net) and filtered to usage_unit='DBU', so bytes/hours/tokens never blend into the DBU total. termination_code/result_state populate only in a run's end row (runs over 1h are sliced hourly), so this filters to result_state IS NOT NULL; termination_code itself was not populated before Aug 2024, and several run columns were not populated before late Nov 2025 - read historical NULLs as unknown, never as a finding. last_failed_termination_code is the code of the most RECENT failed run (by period_start_time), not the alphabetically largest code - a plain MAX(termination_code) would silently pick the wrong value. net_dbus is the exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), not your negotiated invoice rate, and it excludes cloud infra/egress cost - treat it as directional. Cost is attributed by (workspace_id, job_id) over the window, not per run; the cost rollup is pre-aggregated to one row per job before the LEFT JOIN, so result rows are never multiplied.
WITH end_rows AS (
  SELECT workspace_id, job_id, run_id, result_state, termination_code, period_start_time
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= dateadd(day, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())   -- drop incomplete current day
    AND result_state IS NOT NULL                                   -- end row only
),
job_runs AS (
  SELECT workspace_id, job_id,
         COUNT(DISTINCT run_id) AS distinct_runs,
         COUNT(DISTINCT CASE WHEN result_state IN ('FAILED','ERROR','TIMED_OUT')
                             THEN run_id END) AS failed_runs
  FROM end_rows
  GROUP BY workspace_id, job_id
),
-- ARGMAX, not MAX: the termination_code of the LATEST failed run, per (workspace_id, job_id).
-- MAX(termination_code) would pick the lexicographically-largest code, not the most recent.
last_fail AS (
  SELECT workspace_id, job_id, termination_code AS last_failed_termination_code
  FROM end_rows
  WHERE result_state IN ('FAILED','ERROR','TIMED_OUT')
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY workspace_id, job_id ORDER BY period_start_time DESC
  ) = 1
),
-- List price effective at each usage row's time, keyed by sku_name+cloud+usage_unit.
price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
-- DBUs billed to each job over the window. usage_metadata.job_id is unique only within a
-- workspace, so we attribute on (workspace_id, job_id). Net across ALL record_types; DBU only.
-- Pre-aggregated by exactly (workspace_id, job_id) so the LEFT JOIN below stays strictly 1:1.
job_dbus AS (
  SELECT u.workspace_id,
         u.usage_metadata.job_id AS job_id,
         SUM(u.usage_quantity)                            AS net_usage_quantity,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
    AND u.usage_date < current_date()
    AND upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.job_id IS NOT NULL
  GROUP BY u.workspace_id, u.usage_metadata.job_id
)
SELECT r.workspace_id,
       r.job_id,
       r.distinct_runs,
       r.failed_runs,
       lf.last_failed_termination_code,
       COALESCE(d.net_usage_quantity, 0)                                 AS net_job_dbus,
       -- Wasted-DBU proxy: job DBUs scaled by the share of runs that failed. A proxy,
       -- not exact run-level waste (usage_metadata has no run_id) - see caveats.
       CASE WHEN r.distinct_runs > 0
            THEN COALESCE(d.net_usage_quantity, 0) * (r.failed_runs / r.distinct_runs)
            ELSE 0 END                                                   AS wasted_dbus_proxy,
       COALESCE(d.net_usage_quantity, 0)                                 AS net_dbus,
       COALESCE(d.est_usd_list, 0)                                       AS est_usd_list,
       -- status: worst-first band on failed-run count and wasted-DBU magnitude (field heuristic;
       -- :warn_failed_runs/:crit_failed_runs and :warn_wasted_dbus/:crit_wasted_dbus).
       CASE
         WHEN r.failed_runs IS NULL THEN 'NOT_ASSESSED'
         WHEN r.failed_runs >= :crit_failed_runs
           OR (CASE WHEN r.distinct_runs > 0
                    THEN COALESCE(d.net_usage_quantity, 0) * (r.failed_runs / r.distinct_runs)
                    ELSE 0 END) >= :crit_wasted_dbus
         THEN 'CRITICAL'
         WHEN r.failed_runs >= :warn_failed_runs
           OR (CASE WHEN r.distinct_runs > 0
                    THEN COALESCE(d.net_usage_quantity, 0) * (r.failed_runs / r.distinct_runs)
                    ELSE 0 END) >= :warn_wasted_dbus
         THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM job_runs r
LEFT JOIN last_fail lf
  ON r.workspace_id = lf.workspace_id AND r.job_id = lf.job_id
LEFT JOIN job_dbus d
  ON r.workspace_id = d.workspace_id AND r.job_id = d.job_id
WHERE r.failed_runs > 0
ORDER BY wasted_dbus_proxy DESC, failed_runs DESC
