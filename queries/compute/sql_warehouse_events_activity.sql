-- query_id:   sql_warehouse_events_activity
-- source:     system.compute.warehouse_events
-- feeds:      resume/suspend churn; idle warehouses (no recent RUNNING/STARTING);
--             autoscaling behavior (SCALED_UP/SCALED_DOWN + cluster_count); queuing-pressure proxy
-- confidence: confirmed
-- caveats:    Authoritative 6-value event_type enum: SCALED_UP, SCALED_DOWN, STOPPING, RUNNING,
--             STARTING, STOPPED. SCALING_UP/SCALING_DOWN appear in one official sample but are
--             UNDOCUMENTED — do not rely on them. cluster_count = clusters running at event time.
--             Regional.
/* databricks_audit:sql_warehouse_events_activity */
SELECT warehouse_id, event_type,
       COUNT(*)            AS event_count,
       MAX(event_time)     AS last_event_time,
       MIN(event_time)     AS first_event_time,
       MAX(cluster_count)  AS max_cluster_count,
       AVG(cluster_count)  AS avg_cluster_count
FROM system.compute.warehouse_events
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY warehouse_id, event_type
