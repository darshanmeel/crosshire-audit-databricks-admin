-- query_id: access_data_classification_inventory
-- source: system.data_classification.results
-- feeds: classification; classified-but-unmasked (classification side)
-- confidence: confirmed
-- caveats: Deliberately DROPS the samples array<string> (up to 5 raw sample values = sensitive data; never collect). confidence is HIGH/LOW; frequency float 0-1. Covers ENABLED CATALOGS ONLY; unclassified columns absent. Requires BOTH the data-classification feature AND the system.data_classification schema enabled (a SEPARATE schema from system.access — enabling one does not enable the other) — if disabled, emit "schema/feature not enabled", not empty. Preview. 13-month retention. Regional.
/* databricks_audit:access_data_classification_inventory */
SELECT catalog_name, schema_name, table_name, column_name, class_tag, confidence, data_type,
       MAX(frequency)            AS max_frequency,
       MAX(latest_detected_time) AS latest_detected_time,
       MIN(first_detected_time)  AS first_detected_time
FROM system.data_classification.results
WHERE class_tag IS NOT NULL
GROUP BY 1, 2, 3, 4, 5, 6, 7
