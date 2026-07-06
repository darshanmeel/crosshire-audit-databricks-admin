-- query_id:   node_timeline_utilization
-- source:     system.compute.node_timeline
-- feeds:      oversized/right-sizing (CPU/mem utilization vs provisioned capacity);
--             network egress per node (coarse proxy)
-- confidence: confirmed
-- caveats:    Retention 90 DAYS ONLY — :lookback_days must be capped at 90; a 12-month trend
--             silently truncates (degrade to "assessed over last 90 days"). Nodes that ran
--             < 10 minutes MAY NOT APPEAR (short-job blind spot). Classic compute ONLY — no
--             SQL-warehouse/serverless node utilization exists. mem_used_percent includes
--             background processes. (disk_free_bytes_per_mount_point is a map; not selected.)
--             Regional.
/* databricks_audit:node_timeline_utilization */
SELECT cluster_id, node_type, driver,
       COUNT(*) AS minute_rows,
       MIN(start_time) AS first_minute, MAX(end_time) AS last_minute,
       AVG(cpu_user_percent + cpu_system_percent) AS avg_cpu_pct,
       MAX(cpu_user_percent + cpu_system_percent) AS peak_cpu_pct,
       AVG(mem_used_percent) AS avg_mem_pct, MAX(mem_used_percent) AS peak_mem_pct,
       AVG(cpu_wait_percent) AS avg_cpu_wait_pct,
       SUM(network_sent_bytes)     AS total_network_sent_bytes,
       SUM(network_received_bytes) AS total_network_received_bytes
FROM system.compute.node_timeline
WHERE start_time >= current_timestamp() - INTERVAL :lookback_days DAYS
GROUP BY cluster_id, node_type, driver
