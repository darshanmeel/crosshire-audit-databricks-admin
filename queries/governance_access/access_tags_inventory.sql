-- query_id: access_tags_inventory
-- title: Manual governance tags inventory
-- domain: governance_access   tier: standard
-- reads: system.information_schema.column_tags, system.information_schema.table_tags
-- requires: SELECT on system.information_schema; Unity Catalog required
-- empty_if: privilege_scoped
-- params: none - current-state tag rollup, no window.
-- confidence: confirmed
-- confidence_note: column_tags and table_tags are the two tag views transcribed verbatim.
-- read_this: One row = a tag name/value pair at column or table scope, with how many objects carry it. Use it to see your account's actual tagging vocabulary in practice.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: access_pii_propagation_untagged (see where tagged sensitive data flows into untagged targets), access_data_classification_inventory (the auto-detected counterpart to these manual tags)
-- caveats: This uses only COLUMN_TAGS and TABLE_TAGS, the two tag views transcribed verbatim. CATALOG_TAGS, SCHEMA_TAGS, and VOLUME_TAGS exist but their column lists are inferred, not confirmed, so they are excluded - add them only after confirming their columns in your workspace. This is privilege-aware, so the tag inventory is scoped to what the querying principal can see. Manual tags here are a distinct governance mechanism from the auto-detected classification in access_data_classification_inventory.
SELECT 'COLUMN' AS object_scope, TAG_NAME, TAG_VALUE,
       COUNT(*) AS tagged_object_count
FROM system.information_schema.column_tags
GROUP BY 1, 2, 3
UNION ALL
SELECT 'TABLE' AS object_scope, TAG_NAME, TAG_VALUE,
       COUNT(*) AS tagged_object_count
FROM system.information_schema.table_tags
GROUP BY 1, 2, 3
ORDER BY object_scope, TAG_NAME, TAG_VALUE
