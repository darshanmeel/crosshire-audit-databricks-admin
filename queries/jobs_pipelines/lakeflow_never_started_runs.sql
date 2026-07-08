-- query_id: lakeflow_never_started_runs
-- title: Runs that never started execution
-- domain: jobs_pipelines   tier: lite
-- reads: system.lakeflow.job_run_timeline
-- requires: SELECT on system.lakeflow; GA
-- empty_if: schema_not_enabled
-- params: :period_days (default 30) rolling window in days; :warn_never_started (default 3) never-started runs for a (job, termination_code) pair that flags WARN; :crit_never_started (default 10) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: The period_start_time = period_end_time signature for a never-executed run, and termination_code as the reason, were verified against system.lakeflow.job_run_timeline in a live workspace.
-- read_this: One row = a (workspace, job, termination_code) combination. The column that matters is never_started_runs - runs that were created but never began executing (queue rejection, quota hit, config error) before terminating.
-- healthy: never_started_runs at/near 0 for every job - field heuristic; tune :warn_never_started for your account.
-- investigate_if: never_started_runs at/above :warn_never_started (WARN) or :crit_never_started (CRITICAL) for a job/termination_code pair - field heuristic; check termination_code first, it usually names the blocker (queue/quota/config).
-- actions: 1) read the termination_code and, if it is a quota/limit code, check for a scheduling pile-up on that job (free); 2) fix the underlying config error or raise the relevant workspace limit (config); 3) if the block is capacity (queue/cluster limits), add capacity (spend).
-- next: lakeflow_termination_taxonomy (for the account-wide termination_code picture), lakeflow_job_queue_time (queueing and never-started runs often share a capacity root cause)
-- caveats: period_start_time == period_end_time marks a run that never executed; termination_code gives the reason. This is filtered to end rows only, to avoid false positives from clock-hour-aligned slicing of long runs.
SELECT workspace_id, job_id, termination_code,
       COUNT(DISTINCT run_id) AS never_started_runs,
       -- status: worst-first band on never-started run count (field heuristic; :warn_never_started / :crit_never_started).
       CASE
         WHEN COUNT(DISTINCT run_id) >= :crit_never_started THEN 'CRITICAL'
         WHEN COUNT(DISTINCT run_id) >= :warn_never_started THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= dateadd(day, -:period_days, current_date())
  AND period_end_time < date_trunc('DAY', current_timestamp())
  AND result_state IS NOT NULL
  AND period_start_time = period_end_time     -- never began execution
GROUP BY workspace_id, job_id, termination_code
ORDER BY never_started_runs DESC
