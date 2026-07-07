-- query_id: query_queuing_waits
-- title: Queries queued for capacity or compute provisioning
-- domain: performance   tier: standard
-- reads: system.query.history
-- requires: SELECT on system.query; GA (system.query.history is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_queue_secs (default 60) combined queued-for-capacity + waiting-for-compute seconds per day+warehouse that flags WARN; :crit_queue_secs (default 600) ... that flags CRITICAL
-- confidence: confirmed
-- confidence_note: Columns verified against system.query.history in a live workspace.
-- read_this: One row = a day + warehouse whose queries waited before or during execution. The columns that matter are waiting_at_capacity_ms_sum (queued because the warehouse was already at max concurrency/scale) and waiting_for_compute_ms_sum (compute was still provisioning - cold start). A warehouse that shows up here repeatedly on the same day-of-week/hour pattern is under-sized or under-scheduled for its load, not just unlucky once.
-- healthy: waiting_at_capacity_ms_sum + waiting_for_compute_ms_sum below :warn_queue_secs seconds/day per warehouse (field heuristic - tune :warn_queue_secs for your account).
-- investigate_if: combined wait at/above :warn_queue_secs seconds (WARN) or :crit_queue_secs seconds (CRITICAL) - field heuristic; waits that recur on the same warehouse are the real signal, not a single spike.
-- actions: 1) check whether the wait clusters at specific hours before changing anything, e.g. against query_workload_mix_hours (free); 2) raise the warehouse's max clusters/scaling limit, or keep it warm through the busy window with a longer auto-stop (config); 3) split the workload onto a second warehouse, or size up the existing one, if concurrency is structurally too high for one warehouse (spend).
-- next: query_workload_mix_hours (to see if waits line up with a load spike by hour), query_local_spillage (if the same warehouse also spills once queries do get compute)
-- caveats: There are only two queue buckets in system tables: waiting_at_capacity_duration_ms (queued because the warehouse was at capacity) and waiting_for_compute_duration_ms (compute was still being provisioned / cold start) - there is no separate "repair" or "retry" bucket, so a query that failed and retried shows up as ordinary duration, not as a distinct wait category. Databricks' documentation does not specify whether an already-warm warehouse reports 0 or NULL for waiting_for_compute_duration_ms when there is no wait - this query treats NULL and 0 the same way (both mean "no wait"), which is an assumption, not a documented guarantee. This table is regional.
-- system.query.history only captures queries run on SQL warehouses or serverless compute; queries on classic all-purpose or job clusters are never recorded, so a workload that runs largely on classic clusters can look queue-free here even when it isn't.
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       COUNT(*) AS query_count,
       SUM(CASE WHEN waiting_at_capacity_duration_ms > 0 THEN 1 ELSE 0 END) AS queued_at_capacity_count,
       SUM(CASE WHEN waiting_for_compute_duration_ms > 0 THEN 1 ELSE 0 END) AS waited_for_compute_count,
       SUM(waiting_at_capacity_duration_ms)  AS waiting_at_capacity_ms_sum,
       SUM(waiting_for_compute_duration_ms)  AS waiting_for_compute_ms_sum,
       SUM(total_duration_ms)                AS total_duration_ms_sum,
       -- status: worst-first band on combined queue + cold-start seconds (field heuristic; :warn_queue_secs / :crit_queue_secs).
       CASE
         WHEN SUM(waiting_at_capacity_duration_ms) + SUM(waiting_for_compute_duration_ms) >= :crit_queue_secs * 1000 THEN 'CRITICAL'
         WHEN SUM(waiting_at_capacity_duration_ms) + SUM(waiting_for_compute_duration_ms) >= :warn_queue_secs * 1000 THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL :period_days DAYS
  AND start_time < current_date()
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id
ORDER BY (waiting_at_capacity_ms_sum + waiting_for_compute_ms_sum) DESC
