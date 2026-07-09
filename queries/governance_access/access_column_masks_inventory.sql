-- query_id: access_column_masks_inventory
-- title: Column masks inventory
-- domain: governance_access   tier: standard
-- reads: system.information_schema.column_masks
-- requires: SELECT on system.information_schema; Public Preview, DBR 12.2 LTS+, Unity Catalog required
-- empty_if: abac_only, privilege_scoped
-- params: none - static current-state inventory, no window.
-- confidence: needs_confirmation
-- confidence_note: Column names per the official system.information_schema.column_masks reference (docs.databricks.com, 2026-07-09): CATALOG_NAME, SCHEMA_NAME, TABLE_NAME, COLUMN_NAME, MASK_NAME, MASK_COL_USAGE - aliased here to the prior output names (table_catalog/table_schema/using_columns). The earlier 'live workspace' note named table_catalog/table_schema/using_columns, which do not exist on this view; re-verify with a live DESCRIBE.
-- read_this: One row = a column in the metastore that has a column mask attached. The columns that matter are mask_name (which masking function) and using_columns (what it reads to decide the mask).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: access_classified_unmasked (cross-check which classified columns are missing from this list), access_row_filters_inventory (the row-level equivalent)
-- caveats: This is already a compact current-state inventory - one row per masked column, not pre-aggregated. It is privilege-aware: tables visible only via BROWSE are excluded, so treat this as a privilege-scoped inventory, not a complete list of every mask in the metastore. It reads system.information_schema.column_masks, which is Public Preview and requires DBR 12.2 LTS+ - if unsupported on your account, expect an empty or erroring result, not a true zero. system.information_schema is metastore-wide.
-- column_masks lists only manually-applied (ALTER ... SET MASK) masks; ABAC tag-based policy masks never appear here, so an ABAC-governed account can look falsely unmasked - enumerate those via the UC REST API.
SELECT CATALOG_NAME   AS table_catalog,
       SCHEMA_NAME    AS table_schema,
       TABLE_NAME     AS table_name,
       COLUMN_NAME    AS column_name,
       MASK_NAME      AS mask_name,
       MASK_COL_USAGE AS using_columns
FROM system.information_schema.column_masks
ORDER BY table_catalog, table_schema, table_name, column_name
