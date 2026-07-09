-- query_id: access_views_inventory
-- title: View inventory (lineage completeness and materialized views)
-- domain: governance_access   tier: standard
-- reads: system.information_schema.tables, system.information_schema.views
-- requires: SELECT on system.information_schema; Unity Catalog required
-- empty_if: privilege_scoped, no_activity
-- params: :top_n (default 500) row cap - current-state inventory, no window.
-- confidence: needs_confirmation
-- confidence_note: Rebuilt to inventory view/materialized-view objects from system.information_schema.tables (authoritative for TABLE_TYPE incl. MATERIALIZED_VIEW per docs.databricks.com, 2026-07-09), LEFT JOINed to information_schema.views for is_updatable/is_insertable_into/sql_path/view_definition. The prior version selected IS_MATERIALIZED directly from information_schema.views, which has no such column (real columns: TABLE_CATALOG, TABLE_SCHEMA, TABLE_NAME, VIEW_DEFINITION, CHECK_OPTION, IS_UPDATABLE, IS_INSERTABLE_INTO, SQL_PATH); re-verify with a live DESCRIBE. Only view METADATA is emitted, never the view_definition SQL itself.
-- read_this: One row = one view (or materialized view) visible to your grants, with whether it is materialized, updatable/insertable, its sql_path, and the size of its definition. Use it to complete the lineage picture (views mediate table-to-table flows that table lineage may not attribute) and to inventory materialized views (which carry compute + storage cost).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input; is_materialized = true is a cost signal - cross-check spend)
-- next: access_table_lineage_blast_radius (the table lineage these views mediate), access_dead_table_candidates (unused views/tables to retire)
-- caveats: The view_definition SQL is NOT emitted (it can contain sensitive logic) - only its character length (definition_chars) and a derived flag. references_mask_or_filter is a TEXT heuristic (the definition string mentions MASK/FILTER) and is NOT authoritative masked-view detection - a view can wrap a masked table without saying so, and a definition can mention the words for unrelated reasons. system.information_schema is privilege-aware, so views the principal cannot see are absent. is_materialized separates materialized views (compute/storage cost) from plain views. Current-state inventory (no window).
SELECT
  t.TABLE_CATALOG AS view_catalog,
  t.TABLE_SCHEMA  AS view_schema,
  t.TABLE_NAME    AS view_name,
  (t.TABLE_TYPE = 'MATERIALIZED_VIEW') AS is_materialized,
  v.IS_UPDATABLE       AS is_updatable,
  v.IS_INSERTABLE_INTO AS is_insertable_into,
  v.SQL_PATH           AS sql_path,
  LENGTH(v.VIEW_DEFINITION) AS definition_chars,
  CASE WHEN upper(v.VIEW_DEFINITION) LIKE '%MASK%' OR upper(v.VIEW_DEFINITION) LIKE '%FILTER%'
       THEN true ELSE false END AS references_mask_or_filter
FROM system.information_schema.tables t
LEFT JOIN system.information_schema.views v
  ON  v.TABLE_CATALOG = t.TABLE_CATALOG
  AND v.TABLE_SCHEMA  = t.TABLE_SCHEMA
  AND v.TABLE_NAME    = t.TABLE_NAME
WHERE t.TABLE_TYPE IN ('VIEW', 'MATERIALIZED_VIEW')
ORDER BY view_catalog, view_schema, view_name
LIMIT :top_n
