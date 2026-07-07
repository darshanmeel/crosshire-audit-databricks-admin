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
--             net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--               (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in
--               any system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
--             Cost is attributed by warehouse_id (billing ID) over the :period_days window (per-warehouse),
--               not per event/idle-gap. The cost rollup is pre-aggregated then LEFT JOINed, so finding rows
--               are never multiplied. warehouse_id is a globally-unique GUID, so the rollup is keyed on
--               warehouse_id alone (workspace_id dropped) to match this finding's warehouse-only grain.
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
),
price AS (
    SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
           CAST(pricing.default AS DOUBLE) AS list_rate
    FROM system.billing.list_prices
),
cost_rollup AS (
    -- Pre-aggregated per-warehouse DBU/$ over the SAME :period_days window as the finding.
    -- warehouse_id is a globally-unique GUID, so we key on it alone (no workspace_id).
    SELECT
        u.usage_metadata.warehouse_id                    AS warehouse_id,
        SUM(u.usage_quantity)                            AS net_dbus,
        SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
    FROM system.billing.usage u
    LEFT JOIN price p
      ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
     AND u.usage_end_time >= p.price_start_time
     AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
    WHERE upper(u.usage_unit) = 'DBU'
      AND u.usage_metadata.warehouse_id IS NOT NULL
      AND u.usage_date >= current_date() - INTERVAL :period_days DAYS
      AND u.usage_date <  current_date()
    GROUP BY u.usage_metadata.warehouse_id
)
SELECT
    g.warehouse_id,
    COUNT(*)                                                                       AS event_count,
    -- seconds the warehouse held RUNNING before the next event (the auto-stop idle tail lives here)
    SUM(CASE WHEN g.event_type = 'RUNNING'  AND g.gap_seconds IS NOT NULL THEN g.gap_seconds ELSE 0 END) AS running_seconds,
    -- seconds spent STARTING (cold-start tax) and STOPPED (suspended, not billing compute)
    SUM(CASE WHEN g.event_type = 'STARTING' AND g.gap_seconds IS NOT NULL THEN g.gap_seconds ELSE 0 END) AS starting_seconds,
    SUM(CASE WHEN g.event_type = 'STOPPED'  AND g.gap_seconds IS NOT NULL THEN g.gap_seconds ELSE 0 END) AS stopped_seconds,
    -- longest single RUNNING gap = the worst observed idle tail before a stop/next event
    MAX(CASE WHEN g.event_type = 'RUNNING'  AND g.gap_seconds IS NOT NULL THEN g.gap_seconds END)         AS max_running_gap_seconds,
    SUM(CASE WHEN g.event_type = 'RUNNING'  THEN 1 ELSE 0 END)                        AS running_events,
    SUM(CASE WHEN g.event_type = 'STARTING' THEN 1 ELSE 0 END)                        AS starting_events,
    SUM(CASE WHEN g.event_type = 'STOPPED'  THEN 1 ELSE 0 END)                        AS stopped_events,
    -- ADDED cost visibility (see header caveats): exact billed DBUs and list-price $ ESTIMATE for this warehouse
    COALESCE(cr.net_dbus, 0)     AS net_dbus,
    COALESCE(cr.est_usd_list, 0) AS est_usd_list
FROM gaps g
LEFT JOIN cost_rollup cr
  ON g.warehouse_id = cr.warehouse_id
GROUP BY g.warehouse_id, cr.net_dbus, cr.est_usd_list