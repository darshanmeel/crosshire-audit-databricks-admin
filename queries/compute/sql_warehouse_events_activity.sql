-- query_id: sql_warehouse_events_activity
-- title: SQL warehouse event activity (raw event-type breakdown)
-- domain: compute   tier: lite
-- reads: system.compute.warehouse_events
-- requires: SELECT on system.compute; GA
-- empty_if: no_activity
-- params: :period_days (default 30) rolling window in days; :warn_stale_days (default 7) days since a warehouse's last RUNNING/STARTING event that flags WARN; :crit_stale_days (default 14) days that flags CRITICAL
-- confidence: confirmed
-- confidence_note: Event-type enum verified against system.compute.warehouse_events in a live workspace; SCALING_UP/SCALING_DOWN values are undocumented so this query does not rely on them.
-- read_this: One row = one warehouse_id + event_type combination and its event count/cluster-count stats over the window. The columns that matter are event_type (RUNNING/STARTING show the warehouse was actually used; SCALED_UP/SCALED_DOWN show autoscaling churn; STOPPED/STOPPING show suspend behavior) and last_event_time - for a RUNNING or STARTING row, an old last_event_time means this warehouse has gone quiet.
-- healthy: status = OK on the RUNNING/STARTING rows (last RUNNING or STARTING event within :warn_stale_days) - field heuristic; tune for your account's usage cadence.
-- investigate_if: status = WARN or CRITICAL on a RUNNING/STARTING row (no RUNNING or STARTING event for :warn_stale_days / :crit_stale_days) - the warehouse has likely gone dormant. status is NOT_ASSESSED on SCALED_UP/SCALED_DOWN/STOPPED/STOPPING rows - staleness on those event types is not inherently good or bad from this table alone.
-- actions: 1) if a warehouse shows no RUNNING/STARTING activity for a long stretch, confirm with its owner it is still needed before touching config (free); 2) if confirmed unused, lower auto_stop_minutes or pause/decommission it in sql_warehouse_config_current (config); 3) if it is a scheduled/rarely-used warehouse by design, move it to Serverless so idle time between runs costs nothing (spend).
-- next: sql_warehouse_config_current (to check auto_stop_minutes/warehouse_size for a dormant warehouse), compute_warehouse_idle_gaps (for the RUNNING idle-tail duration instead of just event counts), compute_warehouse_autoscale_churn (for the scaling-specific churn signal)
-- caveats: Authoritative 6-value event_type enum for system.compute.warehouse_events is SCALED_UP, SCALED_DOWN, STOPPING, RUNNING, STARTING, STOPPED. SCALING_UP/SCALING_DOWN appear in one official sample but are UNDOCUMENTED - this query does not rely on them, and you should not either. cluster_count is the number of clusters running at event time. Regional - run per metastore region. status is only computed on RUNNING/STARTING rows (a proxy for "is this warehouse still being used"); it is NOT_ASSESSED on SCALED_UP/SCALED_DOWN/STOPPED/STOPPING rows since staleness on those event types does not map to a clean good/bad verdict from this table alone.
SELECT warehouse_id, event_type,
       COUNT(*)            AS event_count,
       MAX(event_time)     AS last_event_time,
       MIN(event_time)     AS first_event_time,
       MAX(cluster_count)  AS max_cluster_count,
       AVG(cluster_count)  AS avg_cluster_count,
       -- status: only meaningful on RUNNING/STARTING rows - days since last RUNNING/STARTING event (field heuristic; :warn_stale_days / :crit_stale_days).
       CASE
         WHEN event_type NOT IN ('RUNNING', 'STARTING') THEN 'NOT_ASSESSED'
         WHEN (unix_timestamp(current_timestamp()) - unix_timestamp(MAX(event_time))) / 86400.0 >= :crit_stale_days THEN 'CRITICAL'
         WHEN (unix_timestamp(current_timestamp()) - unix_timestamp(MAX(event_time))) / 86400.0 >= :warn_stale_days THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.compute.warehouse_events
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY warehouse_id, event_type
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'OK' THEN 2 ELSE 3 END, last_event_time ASC
