-- query_id: access_column_lineage_sensitive_reach
-- title: Column-level lineage reach
-- domain: governance_access   tier: deep
-- reads: system.access.column_lineage
-- requires: SELECT on system.access; GA
-- empty_if: lineage_inference_only, schema_not_enabled
-- params: :period_days (default 30) rolling window in days; :warn_reach_principals (default 10) distinct principals driving one source-target column edge that flags WARN; :crit_reach_principals (default 50) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: All columns used (source/target table and column names, entity_type, direct_access, created_by, event_time) are confirmed against system.access.column_lineage.
-- read_this: One row = a source column x target column data-flow edge (plus entity_type and direct_access) in the window. The columns that matter are event_count (how often that flow ran) and distinct_principals - how many different identities drove it. This is per-edge, not a table-level rollup; pair it with access_table_lineage_blast_radius for the coarser view.
-- healthy: status = OK; distinct_principals below :warn_reach_principals for one source-target column edge - field heuristic.
-- investigate_if: status = WARN at/above :warn_reach_principals, CRITICAL at/above :crit_reach_principals - field heuristic; cross-check the source column against access_data_classification_inventory before prioritizing, since this query itself carries no sensitivity signal.
-- actions: 1) cross-check the source column against access_data_classification_inventory or access_tags_inventory to see if it is actually sensitive (free); 2) if it is, tighten grants on the source or add a mask, and check access_pii_propagation_untagged for the specific untagged-target case (config); 3) if a column is a genuinely critical, widely-reached asset, formalize it as a governed data product with an owner (spend/eng time).
-- next: access_pii_propagation_untagged (the specific untagged-target finding this feeds), access_table_lineage_blast_radius (the table-level rollup)
-- caveats: column_lineage is a SUBSET of all data movement - events with no captured source (e.g. INSERT ... VALUES literals) are NOT captured, so this undercounts; report it as coverage-bounded, never as a complete picture. External/path references show cloud path strings, not table names. statement_id is SQL-warehouse-only. entity_metadata subfields (job_info.job_id, notebook_id, sql_query_id, dlt_pipeline_info.*, genie_space_id, alert_id) are available in the source table for finer attribution but are kept out of this rollup. GA. Regional. This query historically used a 90-day window; set :period_days=90 to reproduce it.
-- Lineage is also not inferred for work run via unsupported paths (RDD, JDBC, spark-submit jobs, UDFs, global temp views) or for pipeline column lineage below DBR 13.3 LTS, so an edge can be wholly absent - low or missing reach is not proof of safety.
SELECT source_table_full_name, source_column_name, target_table_full_name, target_column_name,
       entity_type, direct_access,
       COUNT(*) AS event_count,
       COUNT(DISTINCT created_by) AS distinct_principals,
       MAX(event_time) AS last_event_time,
       -- status: worst-first band on how many distinct principals drove this column-to-column edge (field heuristic; :warn_reach_principals / :crit_reach_principals).
       CASE
         WHEN COUNT(DISTINCT created_by) >= :crit_reach_principals THEN 'CRITICAL'
         WHEN COUNT(DISTINCT created_by) >= :warn_reach_principals THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.access.column_lineage
WHERE source_table_full_name IS NOT NULL
  AND event_date >= current_date() - INTERVAL :period_days DAYS
  AND event_date < current_date()
GROUP BY 1, 2, 3, 4, 5, 6
ORDER BY distinct_principals DESC
