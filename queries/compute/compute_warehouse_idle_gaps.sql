-- query_id:   compute_warehouse_idle_gaps
-- source:     system.compute.warehouse_events
-- feeds:      SQL-warehouse idle time vs auto_stop_minutes — warehouse-idle-1; time a warehouse sat
--             RUNNING before it STOPPED (the auto-stop idle tail), summed per warehouse
-- confidence: confirmed
-- caveats:    Authoritative 6-value event_type enum: SCALED_UP, SCALED_DOWN, STOPPING, RUNNING,
--             STARTING, STOPPED (SCALING_UP/SCALING_DOWN are undocumented and ignored). The gap to the
--             NEXT event is computed with LEAD(event_time) over ALL events for the warehouse ordered by
--             event_time — NOT after filtering to one event_type — so a RUNNING->STOPPED idle tail is
--             measured, not the spacing between RUNNING events. The final event of each warehouse has no
--             next event: its trailing gap is left NULL (open interval), never assumed zero or "still
--             running forever". This rolls up gap seconds BY the state the warehouse held DURING the gap
--             (the event that opened it). A warehouse with activity but zero RUNNING events still appears
--             with running_seconds=0 (the finding LEFT JOINs the full warehouse list so idle/unused
--             warehouses are surfaced, which is the point of the page). Per-event query activity is NOT
--             joined here (that join fans out at day grain and overstates query counts — keep this query
--             event-only). system.compute.warehouse_events carries no DBU/$.
/* databricks_audit:compute_warehouse_idle_gaps */
WITH ordered AS (
    SELECT
        warehouse_id,
        event_type,
        event_time,
        LEAD(event_time) OVER (PARTITION BY warehouse_id ORDER BY event_time) AS next_event_time
    FROM system.compute.warehouse_events
    WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
),
gaps AS (
    SELECT
        warehouse_id,
        event_type,
        -- gap (seconds) this warehouse spent in `event_type` until its NEXT event.
        -- The last event per warehouse has next_event_time = NULL -> gap NULL (open, excluded).
        CASE
            WHEN next_event_time IS NULL THEN NULL
            ELSE unix_timestamp(next_event_time) - unix_timestamp(event_time)
        END AS gap_seconds
    FROM ordered
)
SELECT
    warehouse_id,
    COUNT(*)                                                                       AS event_count,
    -- seconds the warehouse held RUNNING before the next event (the auto-stop idle tail lives here)
    SUM(CASE WHEN event_type = 'RUNNING'  AND gap_seconds IS NOT NULL THEN gap_seconds ELSE 0 END) AS running_seconds,
    -- seconds spent STARTING (cold-start tax) and STOPPED (suspended, not billing compute)
    SUM(CASE WHEN event_type = 'STARTING' AND gap_seconds IS NOT NULL THEN gap_seconds ELSE 0 END) AS starting_seconds,
    SUM(CASE WHEN event_type = 'STOPPED'  AND gap_seconds IS NOT NULL THEN gap_seconds ELSE 0 END) AS stopped_seconds,
    -- longest single RUNNING gap = the worst observed idle tail before a stop/next event
    MAX(CASE WHEN event_type = 'RUNNING'  AND gap_seconds IS NOT NULL THEN gap_seconds END)         AS max_running_gap_seconds,
    SUM(CASE WHEN event_type = 'RUNNING'  THEN 1 ELSE 0 END)                        AS running_events,
    SUM(CASE WHEN event_type = 'STARTING' THEN 1 ELSE 0 END)                        AS starting_events,
    SUM(CASE WHEN event_type = 'STOPPED'  THEN 1 ELSE 0 END)                        AS stopped_events
FROM gaps
GROUP BY warehouse_id
