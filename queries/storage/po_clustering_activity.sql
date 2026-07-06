-- query_id: po_clustering_activity
-- source: system.storage.predictive_optimization_operations_history
-- feeds: clustering activity (automatic clustering / predictive optimization); clustering/PO maintenance cost
-- confidence: confirmed
-- caveats: CLUSTERING has exactly the 4 listed subfields (incremental liquid clustering); all map<string,string> → CAST. Distinct from AUTO_CLUSTERING_COLUMN_SELECTION (different subfields). ESTIMATED_DBU, SUM only.
/* databricks_audit:po_clustering_activity */
SELECT catalog_name, schema_name, table_id, table_name, operation_type,
       COUNT(*) AS op_count,
       SUM(CAST(operation_metrics['number_of_removed_files']        AS BIGINT)) AS removed_files,
       SUM(CAST(operation_metrics['number_of_clustered_files']      AS BIGINT)) AS clustered_files,
       SUM(CAST(operation_metrics['amount_of_data_removed_bytes']   AS BIGINT)) AS removed_bytes,
       SUM(CAST(operation_metrics['amount_of_clustered_data_bytes'] AS BIGINT)) AS clustered_bytes,
       SUM(CAST(usage_quantity AS DECIMAL(38,6)))                              AS clustering_estimated_dbu
FROM system.storage.predictive_optimization_operations_history
WHERE operation_type = 'CLUSTERING'
  AND start_time >= current_date() - INTERVAL 30 DAYS AND start_time < current_date()
GROUP BY catalog_name, schema_name, table_id, table_name, operation_type
