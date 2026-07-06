-- query_id: access_column_masks_inventory
-- source: system.information_schema.column_masks
-- feeds: masking/row-filters inventory; classified-but-unmasked
-- confidence: confirmed (columns verified live 2026-05-30: table_catalog, table_schema, table_name, column_name, mask_name, using_columns)
-- caveats: Already a compact current-state inventory (one row per masked column) — not pre-aggregated. Privilege-aware: BROWSE-only-visible tables excluded -> inventory is privilege-scoped, label completeness. Public Preview + DBR 12.2 LTS+ — degrade by reason if unsupported. system.information_schema is metastore-wide.
/* databricks_audit:access_column_masks_inventory */
SELECT table_catalog, table_schema, table_name, column_name,
       mask_name, using_columns
FROM system.information_schema.column_masks
