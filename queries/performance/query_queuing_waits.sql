-- query_id: query_queuing_waits
-- source: system.query.history
-- feeds: queuing (waiting_*)
-- confidence: confirmed
-- caveats: Two queue buckets only — waiting_at_capacity_duration_ms (queued for capacity) + waiting_for_compute_duration_ms (compute provisioning / cold-start); no separate "repair" bucket. The doc does NOT specify whether warm warehouses report 0 vs NULL for waiting_for_compute — treat NULL/0 both as "no wait" (see checklist). Regional.
/* databricks_audit:query_queuing_waits */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       COUNT(*) AS query_count,
       SUM(CASE WHEN waiting_at_capacity_duration_ms > 0 THEN 1 ELSE 0 END) AS queued_at_capacity_count,
       SUM(CASE WHEN waiting_for_compute_duration_ms > 0 THEN 1 ELSE 0 END) AS waited_for_compute_count,
       SUM(waiting_at_capacity_duration_ms)  AS waiting_at_capacity_ms_sum,
       SUM(waiting_for_compute_duration_ms)  AS waiting_for_compute_ms_sum,
       SUM(total_duration_ms)                AS total_duration_ms_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id
