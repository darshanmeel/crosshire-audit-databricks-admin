-- query_id: table_inventory_type
-- source: system.information_schema.tables
-- feeds: Iceberg / external tables inventory (MANAGED vs EXTERNAL vs VIEW); PO coverage gap (EXTERNAL = not PO-eligible)
-- confidence: needs_confirmation — verifier status `unverifiable`
-- NEEDS WORKSPACE CONFIRMATION: only table_type (MANAGED/EXTERNAL/VIEW) is verbatim-confirmed in the doc; table_catalog, table_schema, and data_source_format are plausible information_schema names but UNVERIFIED. The customer's run validates whether these columns resolve.
-- caveats: information_schema is privilege-aware (collector SP sees only accessible tables) and carries NO size columns — size requires the ANALYZE artifact. data_source_format (DELTA/ICEBERG) helps the iceberg finding but its presence/name is unverified.
/* databricks_audit:table_inventory_type */
-- NEEDS CONFIRMATION: only table_type is doc-confirmed; table_catalog/table_schema/data_source_format
-- are plausible information_schema names but UNVERIFIED.
SELECT table_catalog, table_schema, table_type, data_source_format,
       COUNT(*) AS table_count
FROM system.information_schema.tables
GROUP BY table_catalog, table_schema, table_type, data_source_format
