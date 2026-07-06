-- query_id: access_row_filters_inventory
-- source: system.information_schema.row_filters
-- feeds: masking/row-filters inventory
-- confidence: confirmed (columns verified live 2026-05-30: table_catalog, table_schema, table_name, filter_name, target_columns)
-- caveats: Compact current-state inventory (one row per filtered table). Privilege-aware / object-visibility-scoped. Public Preview + DBR 12.2 LTS+. system.information_schema is metastore-wide.
/* databricks_audit:access_row_filters_inventory */
SELECT table_catalog, table_schema, table_name,
       filter_name, target_columns
FROM system.information_schema.row_filters
