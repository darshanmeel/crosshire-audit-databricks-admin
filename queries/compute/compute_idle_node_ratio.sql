-- query_id: compute_idle_node_ratio
-- title: Idle classic clusters by idle-slice ratio
-- domain: compute   tier: standard
-- reads: system.compute.node_timeline, system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.compute, system.billing; GA
-- empty_if: compute_scope_gap
-- params: :period_days (default 30) rolling window in days, capped at 90 in-SQL by node_timeline retention; :idle_cpu_pct (default 5) CPU busy percent below which a minute-slice counts as idle; :min_slices (default 60) minimum node-minutes before a cluster is judged (fewer -> NOT_ASSESSED); :warn_idle_ratio (default 0.5) idle-slice fraction that flags WARN; :crit_idle_ratio (default 0.8) idle-slice fraction that flags CRITICAL; :top_n (default 200) row cap
-- confidence: confirmed
-- confidence_note: node_timeline columns verified in a live workspace; the est_wasted_usd_list overlay is a directional list-price estimate, not a verified invoice figure.
-- read_this: One row = one classic cluster over the window. idle_ratio (idle minute-slices / total minute-slices) is the column that matters; est_wasted_usd_list scales the cluster's list-price DBU cost by that idle fraction so you can rank the biggest likely savings. High idle_ratio + meaningful est_wasted_usd_list = an auto-stop / downsizing candidate.
-- healthy: idle_ratio below :warn_idle_ratio (field heuristic - tune :warn_idle_ratio for your account).
-- investigate_if: idle_ratio at/above :warn_idle_ratio (WARN) or :crit_idle_ratio (CRITICAL) with real est_wasted_usd_list - field heuristic. BEFORE downsizing, check avg_mem_pct_all: high memory + low CPU means the cluster is memory-bound, NOT idle, so shrinking it will spill.
-- actions: 1) set/shorten auto-termination on the cluster so idle time stops billing (free); 2) enable autoscaling or lower the min workers if the idle is steady-state over-provisioning (config); 3) move the workload to a smaller or memory-optimized node type once you have confirmed it is CPU-idle, not memory-bound (spend).
-- next: compute_warehouse_idle_gaps (if the idle compute is a SQL warehouse, not a classic cluster), cost_by_compute_resource (to see the same cluster's full billed DBUs by day)
-- caveats: node_timeline retention is 90 DAYS ONLY, so :period_days is capped at LEAST(:period_days, 90) in SQL - a longer window silently truncates (read it as "assessed over the last 90 days at most"). Nodes that ran under ~10 minutes MAY NOT APPEAR (short-job blind spot), so a very short cluster is invisible here, not "idle". Classic compute ONLY - there are NO node_timeline rows for SQL warehouses or serverless, so this measure does not cover them. Each row of node_timeline is ONE node-minute (driver AND every worker), so a raw count is NOT hours - idle is reported as a RATIO of slices, never converted to hours. CPU/mem are percents 0-100; mem_used_percent includes background processes. A slice is "idle" by a low-CPU threshold (:idle_cpu_pct) evaluated over ALL slices, never only over already-idle rows. node_timeline carries no DBU/$ column: net_dbus is the exact billed DBUs (usage_unit='DBU') for the cluster and est_usd_list is a LIST-PRICE ESTIMATE (usage_quantity x list_prices.pricing.default), NOT the negotiated invoice rate and excluding cloud infra/egress $. est_wasted_usd_list = est_usd_list x idle_ratio is DIRECTIONAL - it assumes waste is proportional to idle slices, which over-counts when idle time is cheap warm-standby. Cost is attributed by billing cluster_id over the same window (per-cluster, not per node/slice); cluster_id is a globally-unique GUID so cost keys on cluster_id alone.
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
      AND u.usage_date >= dateadd(DAY, -LEAST(:period_days, 90), current_date())
      AND u.usage_date <  current_date()
    GROUP BY u.usage_metadata.cluster_id
),
finding AS (
    SELECT
        cluster_id,
        -- lexicographically-largest node_type label (representative only, not load-weighted)
        MAX(node_type)                                                       AS node_type,
        COUNT(*)                                                             AS total_slices,
        -- idle = CPU busy (user+system) below :idle_cpu_pct on that minute-slice; over ALL slices.
        SUM(CASE WHEN (cpu_user_percent + cpu_system_percent) < :idle_cpu_pct THEN 1 ELSE 0 END) AS idle_slices,
        COUNT(DISTINCT CASE WHEN driver THEN NULL ELSE node_type END)        AS worker_node_type_variants,
        -- utilization averaged over ALL slices (NOT only idle rows) so the mean is honest.
        AVG(cpu_user_percent + cpu_system_percent)                          AS avg_cpu_pct_all,
        MAX(cpu_user_percent + cpu_system_percent)                          AS peak_cpu_pct_all,
        AVG(mem_used_percent)                                               AS avg_mem_pct_all,
        MAX(mem_used_percent)                                               AS peak_mem_pct_all,
        MIN(start_time)                                                     AS first_slice,
        MAX(end_time)                                                       AS last_slice
    FROM system.compute.node_timeline
    WHERE start_time >= dateadd(DAY, -LEAST(:period_days, 90), current_date())
    GROUP BY cluster_id
)
SELECT
    f.cluster_id,
    f.node_type,
    f.total_slices,
    f.idle_slices,
    -- idle_ratio = idle minute-slices / total minute-slices (a fraction 0-1, never "hours").
    f.idle_slices / NULLIF(f.total_slices, 0)                            AS idle_ratio,
    f.worker_node_type_variants,
    f.avg_cpu_pct_all,
    f.peak_cpu_pct_all,
    f.avg_mem_pct_all,
    f.peak_mem_pct_all,
    f.first_slice,
    f.last_slice,
    COALESCE(cr.net_dbus, 0)     AS net_dbus,
    COALESCE(cr.est_usd_list, 0) AS est_usd_list,
    -- directional wasted-$ overlay: list-price cost scaled by the idle fraction.
    COALESCE(cr.est_usd_list, 0) * (f.idle_slices / NULLIF(f.total_slices, 0)) AS est_wasted_usd_list,
    -- status: worst-first band on idle_ratio (field heuristic). Too few slices -> NOT_ASSESSED.
    CASE
      WHEN f.total_slices < :min_slices                                        THEN 'NOT_ASSESSED'
      WHEN f.idle_slices / NULLIF(f.total_slices, 0) >= :crit_idle_ratio       THEN 'CRITICAL'
      WHEN f.idle_slices / NULLIF(f.total_slices, 0) >= :warn_idle_ratio       THEN 'WARN'
      ELSE 'OK'
    END AS status
FROM finding f
LEFT JOIN cost_rollup cr
  ON f.cluster_id = cr.cluster_id
ORDER BY est_wasted_usd_list DESC
LIMIT :top_n
