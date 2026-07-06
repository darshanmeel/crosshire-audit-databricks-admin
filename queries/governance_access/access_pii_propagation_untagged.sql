-- query_id: access_pii_propagation_untagged
-- source: system.access.column_lineage
-- feeds: PII column-propagation gaps (gov-2); masking/classification gaps with responsible created_by
-- confidence: needs_confirmation
-- caveats: Detects PII/sensitive-tagged SOURCE columns flowing via direct_access=true lineage into UNTAGGED target columns. MUST-FIX applied: the target-tag join uses '=' on discrete catalog/schema/table/column columns, NOT LIKE CONCAT(...) — '_' is a LIKE wildcard so an underscore-containing identifier over-matches and would falsely mark targets "TAGGED", hiding real gaps. We restrict to direct_access=true ON PURPOSE: indirect/view-expansion edges are excluded (a view does not re-expose the base PII column as a new physical target column), so view-mediated flows are intentionally invisible here. Tag values are FREE-TEXT and CASE-SENSITIVE, so coverage depends entirely on this account's tagging discipline — an empty result can mean "no PII tagged anywhere", not "no gaps". The PII tag-name set below is a heuristic on tag_name; -- NEEDS WORKSPACE CONFIRMATION: this account's actual sensitivity tag_name / tag_value convention (we match common names case-insensitively and degrade gracefully). information_schema.column_tags is privilege-aware. Retention on system.access.* is workspace-configurable; widen :period_days where retention allows. We exclude the system catalog by name, not a bare NOT LIKE.
/* databricks_audit:access_pii_propagation_untagged */
WITH lineage_window AS (
  SELECT source_table_catalog, source_table_schema, source_table_name, source_column_name,
         target_table_catalog, target_table_schema, target_table_name, target_column_name,
         created_by
  FROM system.access.column_lineage
  WHERE direct_access = true                       -- direct flows only; excludes view expansion
    AND source_column_name IS NOT NULL
    AND target_column_name IS NOT NULL
    AND source_table_catalog <> 'system'
    AND event_date >= dateadd(day, -:period_days, current_date())
    AND event_date < current_date()
),
-- Sensitivity-tagged columns (manual governance tags). We compare on the tag_name
-- against common PII/sensitivity conventions, case-insensitively. -- NEEDS WORKSPACE
-- CONFIRMATION: the real tag_name(s) used here; if the convention differs this set
-- under-detects, which is the safe direction (we never invent a tag match).
sensitive_tags AS (
  SELECT catalog_name, schema_name, table_name, column_name,
         tag_name, tag_value
  FROM system.information_schema.column_tags
  WHERE lower(tag_name) IN (
          'pii', 'sensitivity', 'sensitive', 'data_classification', 'classification',
          'confidentiality', 'phi', 'pci'
        )
     OR lower(tag_value) IN (
          'pii', 'sensitive', 'confidential', 'restricted', 'phi', 'pci'
        )
),
-- Every column that carries ANY governance tag (used to decide if a TARGET is tagged
-- at all). Join with '=' on the four discrete identifier columns (must-fix: never LIKE).
any_tagged_column AS (
  SELECT DISTINCT catalog_name, schema_name, table_name, column_name
  FROM system.information_schema.column_tags
)
SELECT lw.source_table_catalog,
       lw.source_table_schema,
       lw.source_table_name,
       lw.source_column_name,
       st.tag_name  AS source_tag_name,
       st.tag_value AS source_tag_value,
       lw.target_table_catalog,
       lw.target_table_schema,
       lw.target_table_name,
       lw.target_column_name,
       CASE
         WHEN lw.created_by IS NULL OR lw.created_by = '__REDACTED__' THEN lw.created_by
         WHEN lw.created_by LIKE '%@%' THEN concat(substr(lw.created_by, 1, 2), '****@****')
         WHEN lw.created_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN lw.created_by
         ELSE concat(substr(lw.created_by, 1, 2), '****')
       END AS created_by,
       COUNT(*) AS event_count
FROM lineage_window lw
-- SOURCE column must be sensitivity-tagged (= join on discrete columns).
JOIN sensitive_tags st
  ON  lw.source_table_catalog = st.catalog_name
  AND lw.source_table_schema  = st.schema_name
  AND lw.source_table_name    = st.table_name
  AND lw.source_column_name   = st.column_name
-- TARGET column must be UNTAGGED: anti-join against any tag (= join, must-fix).
LEFT JOIN any_tagged_column tt
  ON  lw.target_table_catalog = tt.catalog_name
  AND lw.target_table_schema  = tt.schema_name
  AND lw.target_table_name    = tt.table_name
  AND lw.target_column_name   = tt.column_name
WHERE tt.column_name IS NULL          -- target carries NO governance tag -> propagation gap
GROUP BY lw.source_table_catalog, lw.source_table_schema, lw.source_table_name,
         lw.source_column_name, st.tag_name, st.tag_value,
         lw.target_table_catalog, lw.target_table_schema, lw.target_table_name,
         lw.target_column_name, lw.created_by
