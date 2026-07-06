-- query_id: po_maintenance_cost_by_table
-- source: system.storage.predictive_optimization_operations_history
-- feeds: clustering/PO maintenance cost by table/op; estimated maintenance DBU as a cost line; maintenance success-rate / failing-table; automatic table-maintenance coverage & cost
-- confidence: confirmed
-- caveats: usage_quantity is ESTIMATED_DBU — SUM only. operation_status enum: SUCCESSFUL or 'FAILED: INTERNAL_ERROR' (note the embedded colon). Grouping by operation_status drives the per-table success-rate finding. usage_quantity may lag the op row up to 24h (billing populate) — treat the most recent day as provisional (the start_time < current_date() guard drops today but not yesterday's still-populating values). Public Preview / Regional / 180d retention.
/* databricks_audit:po_maintenance_cost_by_table */
SELECT account_id, workspace_id, metastore_name, catalog_name, schema_name, table_id, table_name,
       operation_type, operation_status, usage_unit,
       COUNT(*)                                  AS operation_count,
       SUM(CAST(usage_quantity AS DECIMAL(38,6))) AS estimated_dbu,
       MIN(start_time) AS first_op_time, MAX(end_time) AS last_op_time
FROM system.storage.predictive_optimization_operations_history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
GROUP BY account_id, workspace_id, metastore_name, catalog_name, schema_name, table_id, table_name,
         operation_type, operation_status, usage_unit
