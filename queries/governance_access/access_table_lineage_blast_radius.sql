-- query_id: access_table_lineage_blast_radius
-- source: system.access.table_lineage
-- feeds: column-lineage blast radius (table-level rollup); access history; lineage coverage
-- confidence: confirmed
-- caveats: source_table_full_name NULL for write-only events; target_table_full_name NULL for read-only (handled by the access_class CASE, which reproduces the documented read/write rule). direct_access=false = indirect/view-expansion access. GA, rolling 365d. Empty lineage = NOT CAPTURED (MERGE/JDBC/path/temp-view gaps), NOT unused — degrade to coverage-gap, never a false negative. Regional.
/* databricks_audit:access_table_lineage_blast_radius */
SELECT source_table_full_name, target_table_full_name, source_type, target_type,
       entity_type, direct_access,
       CASE WHEN source_type IS NOT NULL AND target_type IS NULL THEN 'READ'
            WHEN target_type IS NOT NULL AND source_type IS NULL THEN 'WRITE'
            WHEN source_type IS NOT NULL AND target_type IS NOT NULL THEN 'READ_WRITE'
            ELSE 'UNKNOWN' END AS access_class,
       COUNT(*) AS event_count,
       COUNT(DISTINCT created_by) AS distinct_principals,
       MAX(event_time) AS last_event_time
FROM system.access.table_lineage
WHERE event_date >= current_date() - INTERVAL 90 DAYS
  AND event_date < current_date()
GROUP BY 1, 2, 3, 4, 5, 6, 7
