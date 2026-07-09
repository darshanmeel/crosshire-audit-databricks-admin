-- query_id: access_row_filters_inventory
-- title: Row filters inventory
-- domain: governance_access   tier: standard
-- reads: system.information_schema.row_filters
-- requires: SELECT on system.information_schema; Public Preview, DBR 12.2 LTS+, Unity Catalog required
-- empty_if: abac_only, privilege_scoped
-- params: none - static current-state inventory, no window.
-- confidence: needs_confirmation
-- confidence_note: Column names per the official system.information_schema.row_filters reference (docs.databricks.com, 2026-07-09): CATALOG_NAME, SCHEMA_NAME, TABLE_NAME, FILTER_NAME, FILTER_COL_USAGE - aliased here to the prior output names (table_catalog/table_schema/target_columns). The earlier 'live workspace' note named table_catalog/table_schema/target_columns, which do not exist on this view; re-verify with a live DESCRIBE.
-- read_this: One row = a table in the metastore that has a row-level access filter attached. The columns that matter are filter_name (which filter function) and target_columns (what it evaluates to decide row visibility).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: access_column_masks_inventory (the column-level equivalent), access_grants_inventory (see who has access to these filtered tables)
-- caveats: This is already a compact current-state inventory - one row per filtered table. It is privilege-aware / object-visibility-scoped, so it only shows tables you can see. It reads system.information_schema.row_filters, which is Public Preview and requires DBR 12.2 LTS+. system.information_schema is metastore-wide.
-- It lists only manually-applied (table-level) row filters set via ALTER TABLE; ABAC tag-based policy filters do not appear here, so an ABAC-governed account can look falsely unfiltered - enumerate those via the UC REST API.
SELECT CATALOG_NAME     AS table_catalog,
       SCHEMA_NAME      AS table_schema,
       TABLE_NAME       AS table_name,
       FILTER_NAME      AS filter_name,
       FILTER_COL_USAGE AS target_columns
FROM system.information_schema.row_filters
ORDER BY table_catalog, table_schema, table_name
