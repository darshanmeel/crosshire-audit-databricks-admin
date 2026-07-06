-- query_id: cost_by_compute_resource
-- source: system.billing.usage (usage_metadata.cluster_id / warehouse_id / instance_pool_id)
-- feeds: per-CLUSTER and per-WAREHOUSE DBU cost -> DOLLARIZES cluster right-sizing (which expensive clusters are under-used, not just "149 candidates"), idle-warehouse waste (the 84 zero-event warehouses), warehouse churn, and instance-pool reserve; per-workspace resource cost
-- confidence: confirmed
-- caveats: usage_metadata.{cluster_id, warehouse_id, instance_pool_id} populate for the compute that generated the usage; they are NULL for serverless / account-level lines (those roll up under NULL — keep them, don't drop). NAMES aren't here: join cluster_id -> classic_clusters_config_current and warehouse_id -> sql_warehouse_config_current downstream. usage_quantity is DBU, NOT dollars. Net corrections: SUM across ALL record_types.
/* databricks_audit:cost_by_compute_resource */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.cluster_id        AS cluster_id,
       usage_metadata.warehouse_id      AS warehouse_id,
       usage_metadata.instance_pool_id  AS instance_pool_id,
       product_features.is_serverless   AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity
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
