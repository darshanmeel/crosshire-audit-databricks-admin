-- query_id: cost_by_job
-- title: DBU cost by job
-- domain: cost   tier: standard
-- reads: system.billing.usage
-- requires: SELECT on system.billing; GA (system.billing.usage is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_job_dbus_per_day (default 50) DBUs/day on a single job that flags WARN; :crit_job_dbus_per_day (default 200) DBUs/day that flags CRITICAL
-- confidence: confirmed
-- confidence_note: usage_metadata.job_id and product_features.is_serverless are documented system.billing.usage columns.
-- read_this: One row = a day + workspace + job's DBU cost. The columns that matter are job_id (which job) and net_usage_quantity (its DBU burn that day) - distinct_runs lets you tell a job that is expensive because it runs constantly apart from one that is expensive because a single run is heavy.
-- healthy: net_usage_quantity below :warn_job_dbus_per_day DBUs/day per job (field heuristic - tune :warn_job_dbus_per_day for your account).
-- investigate_if: net_usage_quantity at/above :warn_job_dbus_per_day (WARN) or :crit_job_dbus_per_day (CRITICAL) DBUs/day - field heuristic; a job that is consistently in-band and just large may be fine, a job whose per-run cost keeps climbing is the one to open first.
-- actions: 1) resolve job_id to name/owner/run_as via system.lakeflow.jobs and confirm the job is still needed at this frequency (free); 2) move the job off an always-on all-purpose cluster onto job-scoped compute, or tune its cluster size/autoscaling (config); 3) if the job is genuinely compute-heavy and correctly sized, consider a committed-use discount for that capacity (spend).
-- next: lakeflow_jobs_on_all_purpose (if this job is paying the all-purpose placement premium), lakeflow_failed_runs (if distinct_runs is high relative to net_usage_quantity - retries may be inflating the cost)
-- caveats: usage_metadata.job_id populates for jobs-compute (classic and serverless); it is NULL for interactive / SQL-editor lines and those are excluded here by construction. Names/owner are not here - join job_id -> system.lakeflow.jobs (SCD2, take the latest row by change_time) for the job name and run_as. is_serverless separates jobs-serverless from classic jobs compute, which is the placement-premium signal. usage_quantity is DBU, not dollars.
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.job_id          AS job_id,
       product_features.is_serverless AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity,
       COUNT(DISTINCT usage_metadata.job_run_id) AS distinct_runs,
       -- status: magnitude band on daily DBU cost per job (field heuristic; :warn_job_dbus_per_day / :crit_job_dbus_per_day).
       CASE
         WHEN SUM(usage_quantity) IS NULL THEN 'NOT_ASSESSED'
         WHEN SUM(usage_quantity) >= :crit_job_dbus_per_day THEN 'CRITICAL'
         WHEN SUM(usage_quantity) >= :warn_job_dbus_per_day THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_unit = 'DBU'
  AND usage_metadata.job_id IS NOT NULL
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         usage_metadata.job_id, product_features.is_serverless
ORDER BY net_usage_quantity DESC
