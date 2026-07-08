-- query_id: access_classified_unmasked
-- title: Classified-sensitive columns with no mask applied
-- domain: governance_access   tier: standard
-- reads: system.data_classification.results, system.information_schema.column_masks
-- requires: SELECT on system.data_classification and system.information_schema; system.data_classification is Public Preview and requires Unity Catalog; column_masks is Public Preview (DBR 12.2 LTS+)
-- empty_if: schema_not_enabled, preview_unavailable, no_serverless, abac_only, privilege_scoped
-- params: none - fixed join on catalog/schema/table/column, no rolling window or tunable threshold; status is a direct yes/no on whether a mask exists for the classified column.
-- confidence: confirmed
-- confidence_note: Columns are doc-confirmed. The residual uncertainty is join completeness (column_masks is privilege-aware), not whether the columns exist.
-- read_this: One row = a HIGH-confidence classified (PII/sensitive) column and whether a column mask covers it. The column that matters is is_unmasked - true means the auto-classifier is confident the column is sensitive and no masking function was found on it.
-- healthy: status = OK; is_unmasked = false (a mask is applied) - field heuristic; confirm by reviewing MASK_NAME per column.
-- investigate_if: status = CRITICAL when is_unmasked = true - field heuristic; prioritize columns with the widest access (cross-check against access_grants_inventory).
-- actions: 1) confirm the column is genuinely sensitive by reviewing the class_tag/confidence pair, not the raw values (free); 2) attach a column mask function via ALTER TABLE ... ALTER COLUMN ... SET MASK (config); 3) if masking many columns at scale, standardize on a small set of reusable mask functions instead of one-offs (spend/eng time).
-- next: access_column_masks_inventory (see every mask already in place), access_pii_propagation_untagged (check whether this same sensitive data propagates further, still unmasked)
-- caveats: column_masks is metastore-scoped, privilege-aware, and excludes BROWSE-only tables - a missing mask row can mean the principal running this query simply cannot see it, not that no mask exists. Treat a low unmasked count as a floor, not a guarantee of a clean masking posture, unless the querying principal has broad visibility. Confirm whether system.information_schema in your account covers the whole metastore or only the system catalog - a per-catalog union may be needed for full coverage. column_masks is Public Preview and requires DBR 12.2 LTS+.
-- column_masks lists only manually-applied (ALTER TABLE SET MASK) masks; ABAC tag-based policy masks never appear there, so an ABAC-governed sensitive column can be falsely flagged is_unmasked=true/CRITICAL when a policy already masks it.
SELECT dc.catalog_name, dc.schema_name, dc.table_name, dc.column_name, dc.class_tag, dc.confidence,
       cm.MASK_NAME,
       CASE WHEN cm.MASK_NAME IS NULL THEN true ELSE false END AS is_unmasked,
       -- status: yes/no risk - a HIGH-confidence classified column with no mask applied.
       CASE WHEN cm.MASK_NAME IS NULL THEN 'CRITICAL' ELSE 'OK' END AS status
FROM system.data_classification.results dc
LEFT JOIN system.information_schema.column_masks cm
  ON  cm.CATALOG_NAME = dc.catalog_name
  AND cm.SCHEMA_NAME  = dc.schema_name
  AND cm.TABLE_NAME   = dc.table_name
  AND cm.COLUMN_NAME  = dc.column_name
WHERE dc.confidence = 'HIGH'
  AND dc.class_tag IS NOT NULL
ORDER BY is_unmasked DESC, dc.catalog_name, dc.schema_name, dc.table_name, dc.column_name
