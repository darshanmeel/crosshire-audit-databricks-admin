-- query_id: cost_by_compute_resource
-- title: DBU cost by cluster, warehouse, and pool
-- domain: cost   tier: standard
-- reads: system.billing.usage
-- requires: SELECT on system.billing; GA (system.billing.usage is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_resource_dbus_per_day (default 50) DBUs/day on a single cluster, warehouse, or instance pool that flags WARN; :crit_resource_dbus_per_day (default 200) DBUs/day that flags CRITICAL
-- confidence: confirmed
-- confidence_note: usage_metadata.{cluster_id, warehouse_id, instance_pool_id} and product_features.is_serverless are documented system.billing.usage columns.
-- read_this: One row = a day + workspace + compute resource's DBU cost. The columns that matter are cluster_id/warehouse_id/instance_pool_id (which resource) and net_usage_quantity (its DBU burn for that day) - a resource that stays above the WARN/CRITICAL band day after day is the one worth right-sizing or decommissioning first.
-- healthy: net_usage_quantity below :warn_resource_dbus_per_day DBUs/day per resource (field heuristic - tune :warn_resource_dbus_per_day for your account).
-- investigate_if: net_usage_quantity at/above :warn_resource_dbus_per_day (WARN) or :crit_resource_dbus_per_day (CRITICAL) DBUs/day - field heuristic; a single spike day matters less than the same resource showing up repeatedly.
-- actions: 1) confirm the cluster/warehouse/pool is still needed and not an orphaned always-on resource (free); 2) resolve the resource's name via classic_clusters_config_current or sql_warehouse_config_current and right-size its node type or auto-stop/auto-scale settings (config); 3) move steady-state heavy workloads to a reserved/committed-use tier (spend).
-- next: classic_clusters_config_current (to resolve cluster_id to a name and config), sql_warehouse_config_current (to resolve warehouse_id to a name and config)
-- caveats: usage_metadata.{cluster_id, warehouse_id, instance_pool_id} populate for the compute that generated the usage; they are NULL for serverless / account-level lines - those roll up under NULL and are kept, not dropped. No names are here: join cluster_id -> classic_clusters_config_current and warehouse_id -> sql_warehouse_config_current to get human-readable names. usage_quantity is DBU, not dollars. Net corrections: this sums usage_quantity across all record_types.
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.cluster_id        AS cluster_id,
       usage_metadata.warehouse_id      AS warehouse_id,
       usage_metadata.instance_pool_id  AS instance_pool_id,
       product_features.is_serverless   AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity,
       -- status: magnitude band on daily DBU cost per resource (field heuristic; :warn_resource_dbus_per_day / :crit_resource_dbus_per_day).
       CASE
         WHEN SUM(usage_quantity) IS NULL THEN 'NOT_ASSESSED'
         WHEN SUM(usage_quantity) >= :crit_resource_dbus_per_day THEN 'CRITICAL'
         WHEN SUM(usage_quantity) >= :warn_resource_dbus_per_day THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_unit = 'DBU'
  AND (usage_metadata.cluster_id IS NOT NULL
       OR usage_metadata.warehouse_id IS NOT NULL
       OR usage_metadata.instance_pool_id IS NOT NULL)
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         usage_metadata.cluster_id, usage_metadata.warehouse_id, usage_metadata.instance_pool_id,
         product_features.is_serverless
ORDER BY net_usage_quantity DESC
