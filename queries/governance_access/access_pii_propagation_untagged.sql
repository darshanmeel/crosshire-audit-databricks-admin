-- query_id: access_pii_propagation_untagged
-- title: PII propagation into untagged columns
-- domain: governance_access   tier: standard
-- reads: system.access.column_lineage, system.information_schema.column_tags
-- requires: SELECT on system.access and system.information_schema; system.access.column_lineage is GA; information_schema requires Unity Catalog
-- params: :period_days (default 30) rolling window in days; :warn_pii_gap_events (default 5) times a source-to-target untagged-propagation edge fired that flags WARN; :crit_pii_gap_events (default 50) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: This account's actual sensitivity tag_name/tag_value convention is not confirmed - the query matches common names (pii, sensitivity, sensitive, data_classification, classification, confidentiality, phi, pci) case-insensitively as a heuristic, written to under-detect rather than invent a match, which is the safe direction.
-- read_this: One row = a specific source column (tagged sensitive) that fed, via direct lineage, into a specific target column carrying no governance tag at all. The columns that matter are event_count (how often that flow ran) and created_by (who to talk to about tagging the target).
-- healthy: status = OK; event_count below :warn_pii_gap_events for one source-to-target propagation edge - field heuristic; any row here is already a gap, so "healthy" just means it is not yet a well-established pipeline.
-- investigate_if: status = WARN at/above :warn_pii_gap_events, CRITICAL at/above :crit_pii_gap_events - field heuristic; prioritize edges with a high event_count, since those are recurring, established pipelines, not one-off ad hoc queries.
-- actions: 1) confirm the source column really is sensitive and the target genuinely lacks a tag (free); 2) tag the target column to match the source's classification, or add a column mask if it should stay untagged but restricted (config); 3) if this is a recurring ETL/pipeline pattern, fix the pipeline to propagate tags automatically instead of tagging targets one at a time (spend/eng time).
-- next: access_tags_inventory (see the full tag inventory), access_classified_unmasked (check whether the untagged target is also unmasked)
-- caveats: This detects sensitivity-tagged SOURCE columns that flow, via direct_access=true lineage, into target columns with no governance tag at all. The target-tag join uses exact ('=') matching on the four discrete catalog/schema/table/column columns rather than a LIKE/CONCAT comparison - '_' is a LIKE wildcard, so an underscore in an identifier would otherwise over-match and falsely mark a target "tagged", hiding a real gap. direct_access=true is a deliberate restriction: indirect/view-expansion edges are excluded, because a view does not re-expose the base sensitive column as a new physical target column, so view-mediated flows are intentionally invisible here. Tag values are free-text and case-sensitive, so coverage depends entirely on your account's tagging discipline - an empty result can mean "no PII tagged anywhere", not "no gaps", so verify you actually have sensitivity tags in use before reading zero rows as clean. The PII tag-name set (pii, sensitivity, sensitive, data_classification, classification, confidentiality, phi, pci) is a heuristic on tag_name and tag_value matched case-insensitively - confirm your account's actual sensitivity-tag convention, since this is written to under-detect rather than invent a match. information_schema.column_tags is privilege-aware. Retention on system.access.* tables is workspace-configurable - widen :period_days where your retention allows it. The system catalog is excluded by exact name, not a bare NOT LIKE (which has no wildcard and would behave as <> 'system').
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
-- against common PII/sensitivity conventions, case-insensitively. Confirm the real
-- tag_name(s) used in your account; if the convention differs this set under-detects,
-- which is the safe direction (we never invent a tag match).
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
-- at all). Join with '=' on the four discrete identifier columns (never LIKE).
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
       COUNT(*) AS event_count,
       -- status: worst-first band on how often this untagged-PII-propagation edge fired (field heuristic; :warn_pii_gap_events / :crit_pii_gap_events).
       CASE
         WHEN COUNT(*) >= :crit_pii_gap_events THEN 'CRITICAL'
         WHEN COUNT(*) >= :warn_pii_gap_events THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM lineage_window lw
-- SOURCE column must be sensitivity-tagged (= join on discrete columns).
JOIN sensitive_tags st
  ON  lw.source_table_catalog = st.catalog_name
  AND lw.source_table_schema  = st.schema_name
  AND lw.source_table_name    = st.table_name
  AND lw.source_column_name   = st.column_name
-- TARGET column must be UNTAGGED: anti-join against any tag (= join, never LIKE).
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
ORDER BY event_count DESC
