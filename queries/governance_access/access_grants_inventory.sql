-- query_id: access_grants_inventory
-- source: system.information_schema.table_privileges + catalog_privileges
-- feeds: admin/role hygiene; access history (grant state)
-- confidence: confirmed (these are the only two privilege views transcribed verbatim)
-- caveats: information_schema is PRIVILEGE-AWARE — a principal with MANAGE sees only its OWN grants and only objects it can see; a single SP generally CANNOT enumerate ALL grants. Run as a high-privilege audit SP and STILL label "partial — privilege-aware; incomplete vs SHOW GRANTS", never assert a complete grant graph. IS_GRANTABLE is always 'NO' (reserved) — not collected.
/* databricks_audit:access_grants_inventory */
SELECT object_scope, PRIVILEGE_TYPE,
       CASE
         WHEN GRANTEE IS NULL OR GRANTEE = '__REDACTED__' THEN GRANTEE
         WHEN GRANTEE LIKE '%@%' THEN concat(substr(GRANTEE, 1, 2), '****@****')
         WHEN GRANTEE RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN GRANTEE
         ELSE concat(substr(GRANTEE, 1, 2), '****')
       END AS GRANTEE,
       grant_count, distinct_objects
FROM (
  SELECT 'TABLE' AS object_scope, PRIVILEGE_TYPE, GRANTEE,
         COUNT(*) AS grant_count,
         COUNT(DISTINCT TABLE_CATALOG || '.' || TABLE_SCHEMA || '.' || TABLE_NAME) AS distinct_objects
  FROM system.information_schema.table_privileges
  GROUP BY 1, 2, 3
  UNION ALL
  SELECT 'CATALOG' AS object_scope, PRIVILEGE_TYPE, GRANTEE,
         COUNT(*) AS grant_count,
         COUNT(DISTINCT CATALOG_NAME) AS distinct_objects
  FROM system.information_schema.catalog_privileges
  GROUP BY 1, 2, 3
)
