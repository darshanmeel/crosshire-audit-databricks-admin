-- query_id: lakeflow_failed_runs
-- title: Failed job runs by workspace and termination code
-- domain: jobs_pipelines   tier: lite
-- reads: system.lakeflow.job_run_timeline
-- requires: SELECT on system.lakeflow; GA (system.lakeflow.job_run_timeline is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_failed_run_rows (default 5) failed run rows in a group that flags WARN; :crit_failed_run_rows (default 20) failed run rows that flags CRITICAL
-- confidence: confirmed
-- confidence_note: The result_state filter and the run_rows-vs-distinct_runs distinction were verified against system.lakeflow.job_run_timeline in a live workspace.
-- read_this: One row = a (workspace, run_type, trigger_type, result_state, termination_code) combination in the window. The column that matters is failed_run_rows - how many end rows landed in FAILED/ERROR/TIMED_OUT for that combination; distinct_runs corrects for retries repeating a run_id.
-- healthy: failed_run_rows low relative to distinct_runs, spread across many termination_codes rather than piled on one - field heuristic; tune :warn_failed_run_rows for your account.
-- investigate_if: failed_run_rows at/above :warn_failed_run_rows (WARN) or :crit_failed_run_rows (CRITICAL) for a single termination_code - field heuristic; one code dominating points at a systemic cause, not one-off flakiness.
-- actions: 1) open the top termination_code and read its job's recent run logs for the actual error (free); 2) fix retry/backoff or dependency config so transient causes stop recurring (config); 3) if failures trace back to under-provisioned compute, resize the job cluster (spend).
-- next: lakeflow_termination_taxonomy (for the account-wide termination_code breakdown), lakeflow_failed_jobs_wasted_dbus (for the DBUs each failing job is burning)
-- caveats: The failed filter (result_state IN ('FAILED','ERROR','TIMED_OUT')) is the documented failure set; SKIPPED/CANCELLED/BLOCKED are intentionally not counted as failed. run_rows (raw row count) is not the same as distinct_runs (COUNT DISTINCT run_id), because a retried run repeats its run_id across multiple end rows.
WITH end_rows AS (
  SELECT workspace_id, job_id, run_id, run_type, trigger_type,
         result_state, termination_code, period_start_time, period_end_time
  FROM system.lakeflow.job_run_timeline
  WHERE period_start_time >= dateadd(day, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())   -- drop incomplete current day
    AND result_state IS NOT NULL                                   -- end row only
)
SELECT workspace_id, run_type, trigger_type, result_state, termination_code,
       COUNT(*)              AS run_rows,
       COUNT(DISTINCT run_id) AS distinct_runs,
       SUM(CASE WHEN result_state IN ('FAILED','ERROR','TIMED_OUT') THEN 1 ELSE 0 END) AS failed_run_rows,
       -- status: worst-first band on failed run rows per group (field heuristic; :warn_failed_run_rows / :crit_failed_run_rows).
       CASE
         WHEN SUM(CASE WHEN result_state IN ('FAILED','ERROR','TIMED_OUT') THEN 1 ELSE 0 END) >= :crit_failed_run_rows THEN 'CRITICAL'
         WHEN SUM(CASE WHEN result_state IN ('FAILED','ERROR','TIMED_OUT') THEN 1 ELSE 0 END) >= :warn_failed_run_rows THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM end_rows
GROUP BY workspace_id, run_type, trigger_type, result_state, termination_code
ORDER BY failed_run_rows DESC
