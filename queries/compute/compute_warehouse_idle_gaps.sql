-- query_id: compute_warehouse_idle_gaps
-- title: SQL warehouse idle tail before auto-stop
-- domain: compute   tier: standard
-- reads: system.compute.warehouse_events, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.compute, system.billing; GA
-- params: :period_days (default 30) rolling window in days; :warn_idle_hours (default 4) hours of a single continuous RUNNING stretch that flags WARN; :crit_idle_hours (default 24) hours that flags CRITICAL
-- confidence: confirmed
-- confidence_note: Event-type enum, the gap-window logic (LEAD across ALL events for a warehouse, not per event_type), and the cost-rollup join were all verified against system.compute.warehouse_events and system.billing.usage/list_prices in a live workspace.
-- read_this: One row = one SQL warehouse's time spent in each event state (RUNNING, STARTING, STOPPED) over the window, computed as the gap from each event to that warehouse's very next event (any type). The columns that matter are running_seconds (total time the warehouse sat RUNNING before its next event - a mix of active query time and the idle tail before auto-stop, since per-query activity is deliberately not joined into this query) and max_running_gap_seconds (the single longest continuous RUNNING stretch - an unusually long one usually means the warehouse never triggered its own auto-stop for a long time).
-- healthy: status = OK (max_running_gap_seconds below :warn_idle_hours hours) - field heuristic; tune :warn_idle_hours / :crit_idle_hours to your typical auto_stop_minutes settings.
-- investigate_if: status = WARN or CRITICAL (a single RUNNING stretch at or above :warn_idle_hours / :crit_idle_hours) - field heuristic. status = NOT_ASSESSED means this warehouse had zero RUNNING events in the window (running_seconds=0), which this query still surfaces rather than dropping, since an unused warehouse is itself worth a look.
-- actions: 1) lower auto_stop_minutes on the warehouse in sql_warehouse_config_current so it suspends sooner after the last query (free); 2) route the warehouse's workload onto a shared/Serverless warehouse if it is mostly idle between bursts (config); 3) downsize warehouse_size if the long RUNNING stretch reflects genuinely low, steady load rather than a stuck auto-stop (spend).
-- next: sql_warehouse_config_current (to check this warehouse's auto_stop_minutes), sql_warehouse_events_activity (for the raw event-type breakdown), compute_warehouse_autoscale_churn (if the same warehouse is also thrashing clusters up/down)
-- caveats: Authoritative 6-value event_type enum for system.compute.warehouse_events is SCALED_UP, SCALED_DOWN, STOPPING, RUNNING, STARTING, STOPPED (SCALING_UP/SCALING_DOWN are undocumented and ignored). The gap to the NEXT event is computed with LEAD(event_time) over ALL events for the warehouse ordered by event_time - NOT after filtering to one event_type - so a RUNNING->STOPPED idle tail is measured, not the spacing between RUNNING events only. The final event of each warehouse has no next event: its trailing gap is left NULL (an open interval), never assumed zero or "still running forever". Gap seconds are rolled up BY the state the warehouse held DURING the gap (the event that opened it). This query still returns a row for a warehouse with warehouse_events activity but zero RUNNING events (running_seconds=0), rather than dropping it - the LEFT JOIN to the cost rollup never filters out a warehouse_id, so idle/unused warehouses stay visible here too. Per-event query activity is NOT joined into this query on purpose (that join fans out at day grain and overstates query counts) - keep this query event-only, and read running_seconds as "time RUNNING", not "time definitely idle". system.compute.warehouse_events carries no DBU/$ by itself; net_dbus/est_usd_list come from the separate cost rollup below. net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default) - NOT your negotiated invoice rate (not available in any system table) and excludes cloud infra/egress cost; treat est_usd_list as directional, needs_confirmation. Cost is attributed by warehouse_id (billing ID) over the :period_days window (per-warehouse), not per event/idle-gap - the cost rollup is pre-aggregated before the join, so rows here are never multiplied by it. warehouse_id is a globally-unique GUID, so the rollup is keyed on warehouse_id alone (workspace_id dropped) to match this query's warehouse-only grain.
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
    -- Pre-aggregated per-warehouse DBU/$ over the SAME :period_days window as the query above.
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
    COALESCE(cr.est_usd_list, 0) AS est_usd_list,
    -- status: worst-first band on the single longest continuous RUNNING stretch (field heuristic; :warn_idle_hours / :crit_idle_hours).
    CASE
        WHEN MAX(CASE WHEN g.event_type = 'RUNNING' AND g.gap_seconds IS NOT NULL THEN g.gap_seconds END) IS NULL THEN 'NOT_ASSESSED'
        WHEN MAX(CASE WHEN g.event_type = 'RUNNING' AND g.gap_seconds IS NOT NULL THEN g.gap_seconds END) >= :crit_idle_hours * 3600 THEN 'CRITICAL'
        WHEN MAX(CASE WHEN g.event_type = 'RUNNING' AND g.gap_seconds IS NOT NULL THEN g.gap_seconds END) >= :warn_idle_hours * 3600 THEN 'WARN'
        ELSE 'OK'
    END AS status
FROM gaps g
LEFT JOIN cost_rollup cr
  ON g.warehouse_id = cr.warehouse_id
GROUP BY g.warehouse_id, cr.net_dbus, cr.est_usd_list
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'OK' THEN 2 ELSE 3 END, max_running_gap_seconds DESC
