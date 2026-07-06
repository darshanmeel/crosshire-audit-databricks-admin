-- query_id:   sql_warehouse_config_current
-- source:     system.compute.warehouses
-- feeds:      idle/oversized SQL warehouses; warehouse resume/suspend (config side);
--             chargeback/tagging (warehouse tags); autoscaling config (min/max_clusters)
-- confidence: confirmed
-- caveats:    SCD snapshot: latest row per warehouse_id; delete_time NULL = not deleted.
--             warehouse_size enum incl. 5X_LARGE (Beta on PRO/SERVERLESS). tags is a map.
--             Regional — run per metastore region. (Doc prose says "12 columns" but its own
--             §4 table lists 13; the query uses all 13 — a doc-internal miscount, not an
--             artifact error.)
/* databricks_audit:sql_warehouse_config_current */
SELECT warehouse_id, CASE WHEN warehouse_name IS NULL THEN warehouse_name ELSE concat(substr(warehouse_name, 1, 2), '****') END AS warehouse_name, workspace_id, account_id, warehouse_type, warehouse_channel,
       warehouse_size, min_clusters, max_clusters, auto_stop_minutes, tags, change_time, delete_time
FROM (
  SELECT warehouse_id, warehouse_name, workspace_id, account_id, warehouse_type, warehouse_channel,
         warehouse_size, min_clusters, max_clusters, auto_stop_minutes, tags, change_time, delete_time,
         ROW_NUMBER() OVER (PARTITION BY warehouse_id ORDER BY change_time DESC) AS rn
  FROM system.compute.warehouses
)
WHERE rn = 1 AND delete_time IS NULL
