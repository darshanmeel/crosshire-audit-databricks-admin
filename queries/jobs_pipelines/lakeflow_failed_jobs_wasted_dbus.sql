-- query_id: lakeflow_failed_jobs_wasted_dbus
-- source: system.lakeflow.job_run_timeline JOIN system.billing.usage
-- feeds: Job Health page — top failing jobs ranked by wasted DBUs (reliability-1)
-- confidence: needs_confirmation
-- caveats: WASTED DBUs = the net DBUs billed on usage rows whose usage_metadata.job_id ran a FAILED/ERROR/TIMED_OUT job-run in the window. usage.usage_metadata carries job_id but NOT run_id, so DBUs attribute to the JOB, not the individual failed run — a job that mostly succeeds will over-attribute (disclosed downstream, never presented as exact run-level waste). job_id is unique only WITHIN a workspace -> the usage<->run join is on (workspace_id, job_id), never job_id alone (multi-workspace metastore fan-out is the must-fix). usage_quantity is SUM'd across ALL record_types (ORIGINAL/RETRACTION/RESTATEMENT already net) and filtered to usage_unit='DBU' so bytes/hours/tokens are never blended into the DBU total. termination_code/result_state are populated only in the run END row (>1h runs slice hourly) — filtered to result_state IS NOT NULL. termination_code itself is "not populated before Aug 2024" and several run columns "not populated before late Nov 2025" — historical NULLs are disclosed as unknown, never read as a finding. The dominant termination_code per job is the ARGMAX by period_start_time (latest failure's code), NOT MAX(termination_code) which is lexicographic and wrong (must-fix).
/* databricks_audit:lakeflow_failed_jobs_wasted_dbus */
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
-- DBUs billed to each job over the window. usage_metadata.job_id is unique only within a
-- workspace, so we attribute on (workspace_id, job_id). Net across ALL record_types; DBU only.
job_dbus AS (
  SELECT workspace_id,
         usage_metadata.job_id AS job_id,
         SUM(usage_quantity)   AS net_usage_quantity
  FROM system.billing.usage
  WHERE usage_date >= dateadd(day, -:period_days, current_date())
    AND usage_date < current_date()
    AND upper(usage_unit) = 'DBU'
    AND usage_metadata.job_id IS NOT NULL
  GROUP BY workspace_id, usage_metadata.job_id
)
SELECT r.workspace_id,
       r.job_id,
       r.distinct_runs,
       r.failed_runs,
       lf.last_failed_termination_code,
       COALESCE(d.net_usage_quantity, 0)                                 AS net_job_dbus,
       -- Wasted-DBU proxy: job DBUs scaled by the share of runs that failed. Honest proxy,
       -- not exact run-level waste (usage_metadata has no run_id) — labelled as such downstream.
       CASE WHEN r.distinct_runs > 0
            THEN COALESCE(d.net_usage_quantity, 0) * (r.failed_runs / r.distinct_runs)
            ELSE 0 END                                                   AS wasted_dbus_proxy
FROM job_runs r
LEFT JOIN last_fail lf
  ON r.workspace_id = lf.workspace_id AND r.job_id = lf.job_id
LEFT JOIN job_dbus d
  ON r.workspace_id = d.workspace_id AND r.job_id = d.job_id
WHERE r.failed_runs > 0
