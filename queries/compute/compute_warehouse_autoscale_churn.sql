-- query_id: compute_warehouse_autoscale_churn
-- title: SQL warehouse autoscale churn (scale-up/scale-down thrash)
-- domain: compute   tier: standard
-- reads: system.compute.warehouse_events, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.compute, system.billing; GA
-- params: :period_days (default 30) rolling window in days; :min_observed_hours (default 1) minimum hours between a warehouse's first and last event in the window before a churn rate is reported (guards divide-by-zero and short-span spikes); :warn_churn_per_hour (default 4) scaling events per observed hour that flags WARN; :crit_churn_per_hour (default 10) scaling events per observed hour that flags CRITICAL
-- confidence: confirmed
-- confidence_note: Event-type enum and the cost-rollup join verified against system.compute.warehouse_events and system.billing.usage/list_prices in a live workspace.
-- read_this: One row = one SQL warehouse's scale-up/scale-down activity over the window. The columns that matter are scaling_events (SCALED_UP + SCALED_DOWN counts) and observed_hours (the span between this warehouse's first and last event in the window) - a warehouse thrashing clusters up and down wastes cold-start time and DBUs without necessarily showing up as idle.
-- healthy: status = OK - field heuristic; tune :warn_churn_per_hour / :crit_churn_per_hour for your account.
-- investigate_if: status = WARN or CRITICAL (scaling_events / observed_hours at or above the threshold) - field heuristic. status = NOT_ASSESSED means observed_hours is below :min_observed_hours, i.e. too little history to rate, not a clean bill of health.
-- actions: 1) widen the warehouse's min_clusters/max_clusters autoscale bounds, or switch it to a fixed cluster count, so it stops thrashing (free); 2) raise auto_stop_minutes or route bursty/spiky workloads to a dedicated warehouse so scaling settles (config); 3) move the worst-churning warehouse to Serverless SQL, which absorbs scaling internally (spend).
-- next: sql_warehouse_config_current (to see this warehouse's min_clusters/max_clusters), compute_warehouse_idle_gaps (if the same warehouse also shows a long RUNNING idle tail)
-- caveats: Authoritative event_type enum for system.compute.warehouse_events is SCALED_UP, SCALED_DOWN, STOPPING, RUNNING, STARTING, STOPPED. Only SCALED_UP/SCALED_DOWN count as autoscale churn here. The churn rate is scaling_events / observed_hours; observed_hours is the span between this warehouse's first and last event IN THE WINDOW, not the wall-clock window, so a warehouse seen for only part of the window is not diluted. A warehouse with a single event has a zero/near-zero observed span, so status is NOT_ASSESSED below :min_observed_hours rather than a fabricated spike. cluster_count is clusters running at event time. system.compute.warehouse_events carries no DBU/$ by itself - it is a behavioral churn signal only; net_dbus/est_usd_list come from the separate cost rollup below. net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default) - NOT your negotiated invoice rate (not available in any system table) and excludes cloud infra/egress cost; treat est_usd_list as directional, needs_confirmation. Cost is attributed by billing warehouse_id over the :period_days window (per-resource), not per scaling event - the cost rollup is pre-aggregated before the join, so rows here are never multiplied by it. warehouse_id is a globally-unique GUID, so the cost rollup is keyed on warehouse_id alone (workspace_id is not part of the rollup grain).
WITH price AS (
    SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
           CAST(pricing.default AS DOUBLE) AS list_rate
    FROM system.billing.list_prices
),
cost_rollup AS (
    SELECT u.usage_metadata.warehouse_id                     AS warehouse_id,
           SUM(u.usage_quantity)                             AS net_dbus,
           SUM(u.usage_quantity * COALESCE(p.list_rate, 0))  AS est_usd_list
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
    we.warehouse_id,
    SUM(CASE WHEN event_type = 'SCALED_UP'   THEN 1 ELSE 0 END)        AS scaled_up_events,
    SUM(CASE WHEN event_type = 'SCALED_DOWN' THEN 1 ELSE 0 END)        AS scaled_down_events,
    SUM(CASE WHEN event_type IN ('SCALED_UP','SCALED_DOWN') THEN 1 ELSE 0 END) AS scaling_events,
    COUNT(*)                                                          AS total_events,
    MIN(event_time)                                                   AS first_event_time,
    MAX(event_time)                                                   AS last_event_time,
    -- observed span in hours (first..last event in-window); the driver rate below is scaling_events / this.
    (unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0 AS observed_hours,
    MAX(cluster_count)                                                AS max_cluster_count,
    AVG(cluster_count)                                                AS avg_cluster_count,
    COALESCE(cr.net_dbus, 0)     AS net_dbus,
    COALESCE(cr.est_usd_list, 0) AS est_usd_list,
    -- status: worst-first band on scaling events per observed hour (field heuristic; :warn_churn_per_hour / :crit_churn_per_hour).
    CASE
        WHEN (unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0 < :min_observed_hours THEN 'NOT_ASSESSED'
        WHEN SUM(CASE WHEN event_type IN ('SCALED_UP','SCALED_DOWN') THEN 1 ELSE 0 END)
             / ((unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0) >= :crit_churn_per_hour THEN 'CRITICAL'
        WHEN SUM(CASE WHEN event_type IN ('SCALED_UP','SCALED_DOWN') THEN 1 ELSE 0 END)
             / ((unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0) >= :warn_churn_per_hour THEN 'WARN'
        ELSE 'OK'
    END AS status
FROM system.compute.warehouse_events we
LEFT JOIN cost_rollup cr
    ON we.warehouse_id = cr.warehouse_id
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY we.warehouse_id, cr.net_dbus, cr.est_usd_list
ORDER BY CASE status WHEN 'CRITICAL' THEN 0 WHEN 'WARN' THEN 1 WHEN 'OK' THEN 2 ELSE 3 END, scaling_events DESC
