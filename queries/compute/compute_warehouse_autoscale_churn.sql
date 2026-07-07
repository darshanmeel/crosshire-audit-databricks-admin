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
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing warehouse_id over the window (per-resource), not per scaling event.
--   Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never multiplied.
-- warehouse_id is a globally-unique GUID, so the cost rollup is keyed on warehouse_id alone
--   (workspace_id dropped from the rollup grain since the finding does not carry workspace_id).
/* databricks_audit:compute_warehouse_autoscale_churn */
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
    -- observed span in hours (first..last event in-window); finding divides scaling_events by this.
    (unix_timestamp(MAX(event_time)) - unix_timestamp(MIN(event_time))) / 3600.0 AS observed_hours,
    MAX(cluster_count)                                                AS max_cluster_count,
    AVG(cluster_count)                                                AS avg_cluster_count,
    COALESCE(cr.net_dbus, 0)     AS net_dbus,
    COALESCE(cr.est_usd_list, 0) AS est_usd_list
FROM system.compute.warehouse_events we
LEFT JOIN cost_rollup cr
    ON we.warehouse_id = cr.warehouse_id
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY we.warehouse_id, cr.net_dbus, cr.est_usd_list