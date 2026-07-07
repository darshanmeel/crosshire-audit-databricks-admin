-- query_id: access_table_lineage_blast_radius
-- title: Table-level lineage blast radius
-- domain: governance_access   tier: standard
-- reads: system.access.table_lineage
-- requires: SELECT on system.access; GA
-- params: :period_days (default 30) rolling window in days; :warn_blast_principals (default 10) distinct principals driving one source-target edge that flags WARN; :crit_blast_principals (default 50) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: source_table_full_name is NULL for write-only events and target_table_full_name is NULL for read-only events; the access_class CASE reproduces Databricks' documented read/write rule from those two columns.
-- read_this: One row = a source table x target table data-flow edge (plus type, entity_type, and direct_access) in the window. The columns that matter are access_class (READ/WRITE/READ_WRITE/UNKNOWN) and distinct_principals - how many different identities drove that specific flow. This is per-edge, not a full fan-out count; to see everything one source table touches, aggregate this result by source_table_full_name yourself.
-- healthy: status = OK; distinct_principals below :warn_blast_principals for one source-target edge - field heuristic.
-- investigate_if: status = WARN at/above :warn_blast_principals, CRITICAL at/above :crit_blast_principals - field heuristic; an edge with direct_access=true, a sensitive-looking source, and high distinct_principals is the highest-priority combination to review.
-- actions: 1) confirm the source table's sensitivity via access_data_classification_inventory before treating a wide edge as risky (free); 2) tighten grants on the source table if the fan-out is broader than intended (config); 3) if this is a genuinely critical shared table, formalize it as a governed data product with an owner and change-review process (spend/eng time).
-- next: access_column_lineage_sensitive_reach (the column-level equivalent), access_pii_propagation_untagged (check if this edge is also an untagged PII gap)
-- caveats: source_table_full_name is NULL for write-only events and target_table_full_name is NULL for read-only events - the access_class column reproduces Databricks' documented read/write rule from those two columns. direct_access=false means an indirect or view-expansion access. This reads system.access.table_lineage, which is GA with a rolling 365-day retention. An empty result for a table you know is used means the lineage event was simply not captured (MERGE, JDBC, path-based, or temp-view access all have gaps), not that the table is unused - degrade to a coverage gap, never a false negative. Regional. This query historically used a 90-day window; set :period_days=90 to reproduce it.
SELECT source_table_full_name, target_table_full_name, source_type, target_type,
       entity_type, direct_access,
       CASE WHEN source_type IS NOT NULL AND target_type IS NULL THEN 'READ'
            WHEN target_type IS NOT NULL AND source_type IS NULL THEN 'WRITE'
            WHEN source_type IS NOT NULL AND target_type IS NOT NULL THEN 'READ_WRITE'
            ELSE 'UNKNOWN' END AS access_class,
       COUNT(*) AS event_count,
       COUNT(DISTINCT created_by) AS distinct_principals,
       MAX(event_time) AS last_event_time,
       -- status: worst-first band on how many distinct principals drove this source-target edge (field heuristic; :warn_blast_principals / :crit_blast_principals).
       CASE
         WHEN COUNT(DISTINCT created_by) >= :crit_blast_principals THEN 'CRITICAL'
         WHEN COUNT(DISTINCT created_by) >= :warn_blast_principals THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.access.table_lineage
WHERE event_date >= current_date() - INTERVAL :period_days DAYS
  AND event_date < current_date()
GROUP BY 1, 2, 3, 4, 5, 6, 7
ORDER BY distinct_principals DESC
