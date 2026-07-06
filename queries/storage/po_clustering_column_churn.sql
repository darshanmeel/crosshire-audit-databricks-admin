-- query_id: po_clustering_column_churn
-- source: system.storage.predictive_optimization_operations_history
-- feeds: clustering-column churn (unstable/poorly chosen liquid-clustering keys); clustering activity
-- confidence: confirmed
-- caveats: Exactly 4 subfields; all STRING values (categorical, no CAST). old_clustering_columns = 'None' if unpartitioned. has_column_selection_changed = true churn = layout instability.
/* databricks_audit:po_clustering_column_churn */
SELECT catalog_name, schema_name, table_id, table_name,
       operation_metrics['has_column_selection_changed'] AS has_column_selection_changed,
       operation_metrics['old_clustering_columns']        AS old_clustering_columns,
       operation_metrics['new_clustering_columns']        AS new_clustering_columns,
       operation_metrics['additional_reason']             AS additional_reason,
       MAX(end_time) AS last_selection_time,
       COUNT(*)      AS selection_event_count
FROM system.storage.predictive_optimization_operations_history
WHERE operation_type = 'AUTO_CLUSTERING_COLUMN_SELECTION'
  AND start_time >= current_date() - INTERVAL 30 DAYS AND start_time < current_date()
GROUP BY catalog_name, schema_name, table_id, table_name,
         operation_metrics['has_column_selection_changed'], operation_metrics['old_clustering_columns'],
         operation_metrics['new_clustering_columns'], operation_metrics['additional_reason']
