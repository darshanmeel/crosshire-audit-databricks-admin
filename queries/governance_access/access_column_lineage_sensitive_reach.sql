-- query_id: access_column_lineage_sensitive_reach
-- source: system.access.column_lineage
-- feeds: column-lineage blast radius; classified-but-unmasked (reach side); access history
-- confidence: confirmed
-- caveats: column_lineage is a SUBSET — events with no source (e.g. INSERT ... VALUES literals) are NOT captured, so this undercounts; report as coverage-bounded. External/path refs show cloud path strings, not table names. statement_id is SQL-warehouse-only. entity_metadata subfields (job_info.job_id, notebook_id, sql_query_id, dlt_pipeline_info.*, genie_space_id, alert_id) are available for finer attribution but kept out of this rollup. GA. Regional.
/* databricks_audit:access_column_lineage_sensitive_reach */
SELECT source_table_full_name, source_column_name, target_table_full_name, target_column_name,
       entity_type, direct_access,
       COUNT(*) AS event_count,
       COUNT(DISTINCT created_by) AS distinct_principals,
       MAX(event_time) AS last_event_time
FROM system.access.column_lineage
WHERE source_table_full_name IS NOT NULL
  AND event_date >= current_date() - INTERVAL 90 DAYS
  AND event_date < current_date()
GROUP BY 1, 2, 3, 4, 5, 6
