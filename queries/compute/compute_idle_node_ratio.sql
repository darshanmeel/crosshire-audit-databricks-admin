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
/* databricks_audit:compute_idle_node_ratio */
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
