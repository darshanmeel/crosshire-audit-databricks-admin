-- query_id:   compute_warehouse_autoscale_churn
-- source:     system.compute.warehouse_events
-- feeds:      autoscaling churn (SCALED_UP/SCALED_DOWN per hour) — autoscale-1; warehouses thrashing
--             clusters up and down (cold-start + spin-up waste)
-- confidence: confirmed
-- caveats:    Authoritative event_type enum: SCALED_UP, SCALED_DOWN, STOPPING, RUNNING, STARTING,
--             STOPPED. Only SCALED_UP/SCALED_DOWN count as autoscale churn here. The churn RATE is
--             (scaling events / hours observed); hours_observed is the span between this warehouse's
--             first and last event IN THE WINDOW, NOT the wall-clock window, so a warehouse seen for
--             only part of the window is not diluted. A warehouse with a single event has a zero/near-
--             zero observed span — the finding guards against a divide-by-zero by requiring a minimum
--             observed span before reporting a rate (otherwise rate is left NULL = "not enough events
--             to rate", never a fabricated spike). cluster_count = clusters running at event time.
--             system.compute.warehouse_events carries no DBU/$ — this is a behavioral churn signal only.
/* databricks_audit:compute_warehouse_autoscale_churn */
SELECT
    warehouse_id,
    SUM(CASE WHEN event_type = 'SCALED_UP'   THEN 1 ELSE 0 END)        AS scaled_up_events,
    SUM(CASE WHEN event_type = 'SCALED_DOWN' THEN 1 ELSE 0 END)        AS scaled_down_events,
    SUM(CASE WHEN event_type IN ('SCALED_UP','SCALED_DOWN') THEN 1 ELSE 0 END) AS scaling_events,
    COUNT(*)                                                          AS total_events,
    MIN(event_time)                                                   AS first_event_time,
    MAX(event_time)                                                   AS last_event_time,
    -- observed span in hours (first..last event in-window); finding divides scaling_events by this.
    (unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0 AS observed_hours,
    MAX(cluster_count)                                                AS max_cluster_count,
    AVG(cluster_count)                                                AS avg_cluster_count
FROM system.compute.warehouse_events
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY warehouse_id
