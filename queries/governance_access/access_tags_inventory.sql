-- query_id: access_tags_inventory
-- source: system.information_schema.column_tags + table_tags
-- feeds: classification (manual tags)
-- confidence: confirmed (the two tag views transcribed verbatim)
-- caveats: Uses ONLY COLUMN_TAGS and TABLE_TAGS (verbatim-confirmed). CATALOG_TAGS/SCHEMA_TAGS/VOLUME_TAGS are inferred-only and EXCLUDED (add only after confirming their column lists — see checklist). Privilege-aware -> tag inventory is privilege-scoped. Manual tags here are distinct from auto-detected classification in data_classification.results.
/* databricks_audit:access_tags_inventory */
SELECT 'COLUMN' AS object_scope, TAG_NAME, TAG_VALUE,
       COUNT(*) AS tagged_object_count
FROM system.information_schema.column_tags
GROUP BY 1, 2, 3
UNION ALL
SELECT 'TABLE' AS object_scope, TAG_NAME, TAG_VALUE,
       COUNT(*) AS tagged_object_count
FROM system.information_schema.table_tags
GROUP BY 1, 2, 3
