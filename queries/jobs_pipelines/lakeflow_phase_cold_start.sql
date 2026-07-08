-- query_id: lakeflow_phase_cold_start
-- title: Job run phase breakdown - setup, queue, execution, cleanup
-- domain: jobs_pipelines   tier: lite
-- reads: system.lakeflow.job_run_timeline
-- requires: SELECT on system.lakeflow; GA (the five *_duration_seconds columns were added early Dec 2025)
-- empty_if: schema_not_enabled
-- params: :period_days (default 30) rolling window in days; :warn_setup_p95_s (default 60) 95th-percentile setup seconds that flags WARN; :crit_setup_p95_s (default 300) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: The five phase columns and the queue-vs-job_task_run_timeline scoping were verified against system.lakeflow.job_run_timeline in a live workspace.
-- read_this: One row = a job in the window. The column that matters is setup_s_p95 - the 95th-percentile cold-start (cluster setup) seconds before a run's code starts executing; execution_s_total is how much of the run's time was actual work.
-- healthy: setup_s_p95 below :warn_setup_p95_s seconds - field heuristic; tune :warn_setup_p95_s for your account.
-- investigate_if: setup_s_p95 at/above :warn_setup_p95_s (WARN) or :crit_setup_p95_s (CRITICAL) seconds - field heuristic; also check rows_setup_null before trusting a low number on a short-history account.
-- actions: 1) switch the job to a job cluster/pool that is already warm, or share a cluster across tasks in the same job (free); 2) enable a cluster pool or serverless compute to cut cold-start time (config); 3) keep a small always-on pool of pre-warmed instances if setup latency is business-critical (spend).
-- next: lakeflow_job_queue_time (queue time is one slice of this same breakdown, isolated), lakeflow_workload_mix_hours (to see whether the affected job runs often enough to be worth the fix)
-- caveats: All five *_duration_seconds columns are not populated before early Dec 2025, so on a short-history account they are NULL; rows_setup_null exposes this so this query degrades rather than inferring zero startup overhead. queue_duration_seconds exists only on job_run_timeline, not on job_task_run_timeline. This query uses the exact PERCENTILE function; on large volumes prefer PERCENTILE_APPROX instead, since exact PERCENTILE can be expensive.
SELECT workspace_id, job_id,
       COUNT(DISTINCT run_id)                    AS runs,
       SUM(setup_duration_seconds)               AS setup_s_total,
       SUM(queue_duration_seconds)               AS queue_s_total,
       SUM(execution_duration_seconds)           AS execution_s_total,
       SUM(cleanup_duration_seconds)             AS cleanup_s_total,
       SUM(run_duration_seconds)                 AS run_s_total,
       PERCENTILE(setup_duration_seconds, 0.95)  AS setup_s_p95,
       PERCENTILE(queue_duration_seconds, 0.95)  AS queue_s_p95,
       SUM(CASE WHEN setup_duration_seconds IS NULL THEN 1 ELSE 0 END) AS rows_setup_null,
       -- status: worst-first band on p95 setup (cold-start) seconds (field heuristic; :warn_setup_p95_s / :crit_setup_p95_s).
       CASE
         WHEN PERCENTILE(setup_duration_seconds, 0.95) IS NULL THEN 'NOT_ASSESSED'
         WHEN PERCENTILE(setup_duration_seconds, 0.95) >= :crit_setup_p95_s THEN 'CRITICAL'
         WHEN PERCENTILE(setup_duration_seconds, 0.95) >= :warn_setup_p95_s THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= dateadd(day, -:period_days, current_date())
  AND period_end_time < date_trunc('DAY', current_timestamp())
  AND result_state IS NOT NULL     -- end row carries the final durations
GROUP BY workspace_id, job_id
ORDER BY setup_s_p95 DESC
