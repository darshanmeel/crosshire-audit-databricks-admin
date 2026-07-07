-- query_id:   compute_idle_node_ratio
-- source:     system.compute.node_timeline
-- feeds:      idle clusters by IDLE RATIO (idle minute-slices / total minute-slices) — idle-1;
--             auto-stop / auto-termination candidates among classic compute
-- confidence: confirmed
-- caveats:    Retention 90 DAYS ONLY — :lookback_days is capped at 90 by the collector; a longer
--             window silently truncates (degrade to "assessed over last 90 days"). Nodes that ran
--             < 10 minutes MAY NOT APPEAR (short-job blind spot) so very short clusters are invisible,
--             not "idle". Classic compute ONLY — there are NO node_timeline rows for SQL warehouses
--             or serverless, so this idle measure does not cover them. Each row is ONE node-minute
--             (driver AND every worker), so a raw row count is NOT "hours" — we report idle slices /
--             total slices (a RATIO) and the finding never converts row counts to hours. CPU/mem are
--             percentages 0-100; mem_used_percent includes background processes. A slice is counted
--             "idle" by a LOW-CPU threshold evaluated over ALL slices (never only over already-idle
--             rows — that would be ~0 by construction). System carries no DBU/$ on node_timeline.
--             net_dbus is exact billed DBUs (usage_unit='DBU') for the cluster; est_usd_list is a
--               LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default) -- NOT the negotiated
--               invoice rate (not in any system table) and excludes cloud infra/egress $. Directional,
--               needs_confirmation.
--             Cost is attributed by billing cluster_id over the same :lookback_days window (per-cluster),
--               not per node/slice. Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are
--               never multiplied. cluster_id is a globally-unique GUID so cost is keyed on cluster_id
--               alone (finding carries no workspace_id).
/* databricks_audit:compute_idle_node_ratio */
WITH price AS (
    SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
           CAST(pricing.default AS DOUBLE) AS list_rate
    FROM system.billing.list_prices
),
cost_rollup AS (
    -- Pre-aggregated per cluster_id (globally-unique GUID -> workspace_id not needed for the join).
    SELECT u.usage_metadata.cluster_id                         AS cluster_id,
           SUM(u.usage_quantity)                               AS net_dbus,
           SUM(u.usage_quantity * COALESCE(p.list_rate, 0))    AS est_usd_list
    FROM system.billing.usage u
    LEFT JOIN price p
      ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
     AND u.usage_end_time >= p.price_start_time
     AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
    WHERE upper(u.usage_unit) = 'DBU'
      AND u.usage_metadata.cluster_id IS NOT NULL
      AND u.usage_date >= date(current_timestamp() - INTERVAL :lookback_days DAYS)
      AND u.usage_date <  current_date()
    GROUP BY u.usage_metadata.cluster_id
),
finding AS (
    SELECT
        cluster_id,
        -- lexicographically-largest node_type label (representative only, not load-weighted)
        MAX(node_type)                                                       AS node_type,
        COUNT(*)                                                             AS total_slices,
        -- idle = CPU busy (user+system) below 5% on that minute-slice; evaluated over ALL slices.
        SUM(CASE WHEN (cpu_user_percent + cpu_system_percent) < 5 THEN 1 ELSE 0 END) AS idle_slices,
        COUNT(DISTINCT CASE WHEN driver THEN NULL ELSE node_type END)        AS worker_node_type_variants,
        -- utilization averaged over ALL slices (NOT only idle rows) so the mean is honest.
        AVG(cpu_user_percent + cpu_system_percent)                          AS avg_cpu_pct_all,
        MAX(cpu_user_percent + cpu_system_percent)                          AS peak_cpu_pct_all,
        AVG(mem_used_percent)                                               AS avg_mem_pct_all,
        MAX(mem_used_percent)                                               AS peak_mem_pct_all,
        MIN(start_time)                                                     AS first_slice,
        MAX(end_time)                                                       AS last_slice
    FROM system.compute.node_timeline
    WHERE start_time >= current_timestamp() - INTERVAL :lookback_days DAYS
    GROUP BY cluster_id
)
SELECT
    f.cluster_id,
    f.node_type,
    f.total_slices,
    f.idle_slices,
    f.worker_node_type_variants,
    f.avg_cpu_pct_all,
    f.peak_cpu_pct_all,
    f.avg_mem_pct_all,
    f.peak_mem_pct_all,
    f.first_slice,
    f.last_slice,
    COALESCE(cr.net_dbus, 0)     AS net_dbus,
    COALESCE(cr.est_usd_list, 0) AS est_usd_list
FROM finding f
LEFT JOIN cost_rollup cr
  ON f.cluster_id = cr.cluster_id