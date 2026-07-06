-- query_id: access_classified_unmasked
-- source: system.data_classification.results LEFT JOIN system.information_schema.column_masks
-- feeds: classified-but-unmasked; masking inventory
-- confidence: confirmed on columns (verifier ok); methodologically needs care — see caveats. Every column is doc-confirmed; the residual risk is join completeness, not column existence.
-- caveats: column_masks is metastore-scoped, privilege-aware, and excludes BROWSE-only tables — a missing mask row may mean "not visible to the collector SP", which would OVERSTATE is_unmasked. The SP must have sufficient privilege; otherwise label completeness, do not assert a clean unmasked count. Confirm whether system.information_schema covers the whole metastore or only the system catalog (a per-catalog union may be needed). COLUMN_MASKS is Public Preview, DBR 12.2 LTS+.
/* databricks_audit:access_classified_unmasked */
SELECT dc.catalog_name, dc.schema_name, dc.table_name, dc.column_name, dc.class_tag, dc.confidence,
       cm.MASK_NAME,
       CASE WHEN cm.MASK_NAME IS NULL THEN true ELSE false END AS is_unmasked
FROM system.data_classification.results dc
LEFT JOIN system.information_schema.column_masks cm
  ON  cm.CATALOG_NAME = dc.catalog_name
  AND cm.SCHEMA_NAME  = dc.schema_name
  AND cm.TABLE_NAME   = dc.table_name
  AND cm.COLUMN_NAME  = dc.column_name
WHERE dc.confidence = 'HIGH'
  AND dc.class_tag IS NOT NULL
