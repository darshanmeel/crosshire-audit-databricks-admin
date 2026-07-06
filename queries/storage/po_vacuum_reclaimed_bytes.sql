-- query_id: po_vacuum_reclaimed_bytes
-- source: system.storage.predictive_optimization_operations_history
-- feeds: time-travel / storage bloat reclaimed (VACUUM bytes); PO coverage gap (pairs reclaimed bytes with vacuumable_bytes)
-- confidence: confirmed
-- caveats: VACUUM has exactly 2 documented subfields: number_of_deleted_files, amount_of_data_deleted_bytes (both map<string,string> → CAST). Databricks has no fail-safe.
/* databricks_audit:po_vacuum_reclaimed_bytes */
SELECT catalog_name, schema_name, table_id, table_name,
       COUNT(*) AS vacuum_op_count,
       SUM(CAST(operation_metrics['number_of_deleted_files']      AS BIGINT))  AS total_deleted_files,
       SUM(CAST(operation_metrics['amount_of_data_deleted_bytes'] AS BIGINT))  AS total_deleted_bytes,
       SUM(CAST(usage_quantity AS DECIMAL(38,6)))                              AS vacuum_estimated_dbu
FROM system.storage.predictive_optimization_operations_history
WHERE operation_type = 'VACUUM' AND operation_status = 'SUCCESSFUL'
  AND start_time >= current_date() - INTERVAL 30 DAYS AND start_time < current_date()
GROUP BY catalog_name, schema_name, table_id, table_name
