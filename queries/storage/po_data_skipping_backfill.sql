-- query_id: po_data_skipping_backfill
-- source: system.storage.predictive_optimization_operations_history
-- feeds: data-skipping / pruning maintenance (which columns got stats backfilled); search optimization (data-skipping coverage)
-- confidence: confirmed
-- caveats: DATA_SKIPPING_COLUMN_SELECTION has exactly 6 documented subfields (the 6th, old_data_skipping_columns, is real but not selected here — manifest-consistency note, not a correctness issue). Byte/file fields CAST; column-list fields STRING. The actual prune ratio is NOT here — it lives in system.query.history (the query group); this only shows stats were backfilled.
/* databricks_audit:po_data_skipping_backfill */
SELECT catalog_name, schema_name, table_id, table_name,
       operation_metrics['added_data_skipping_columns']   AS added_data_skipping_columns,
       operation_metrics['removed_data_skipping_columns'] AS removed_data_skipping_columns,
       operation_metrics['new_data_skipping_columns']     AS new_data_skipping_columns,
       SUM(CAST(operation_metrics['amount_of_scanned_bytes'] AS BIGINT)) AS scanned_bytes,
       SUM(CAST(operation_metrics['number_of_scanned_files'] AS BIGINT)) AS scanned_files,
       MAX(end_time) AS last_event_time
FROM system.storage.predictive_optimization_operations_history
WHERE operation_type = 'DATA_SKIPPING_COLUMN_SELECTION'
  AND start_time >= current_date() - INTERVAL 30 DAYS AND start_time < current_date()
GROUP BY catalog_name, schema_name, table_id, table_name,
         operation_metrics['added_data_skipping_columns'], operation_metrics['removed_data_skipping_columns'],
         operation_metrics['new_data_skipping_columns']
