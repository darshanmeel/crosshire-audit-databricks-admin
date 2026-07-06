-- query_id: access_grants_inventory_extended
-- source: system.information_schema.{schema_privileges, connection_privileges, credential_privileges, external_location_privileges} (+ routine/volume/metastore exist but are not queried)
-- feeds: admin/role hygiene; integrations (connections/credentials/external locations)
-- confidence: needs_confirmation — verifier status unverifiable
-- NEEDS WORKSPACE CONFIRMATION: per-view object-name columns for the sibling *_PRIVILEGES views (e.g. SCHEMA_PRIVILEGES.CATALOG_NAME+SCHEMA_NAME, the CONNECTION/CREDENTIAL/EXTERNAL_LOCATION name columns). Only TABLE_PRIVILEGES and CATALOG_PRIVILEGES are transcribed column-by-column; the sibling column lists are inferred. The executed SQL safely uses only GRANTEE + PRIVILEGE_TYPE (shared across all privilege views), so it holds — but do not rely on the object-name columns until each view is DESCRIBEd.
-- caveats: Views EXIST per §5; their exact column names beyond the shared GRANTOR/GRANTEE/PRIVILEGE_TYPE/IS_GRANTABLE/INHERITED_FROM shape are NOT verified column-by-column. STORAGE_CREDENTIAL_PRIVILEGES is deprecated — excluded. Same privilege-aware incompleteness caveat as access_grants_inventory.
/* databricks_audit:access_grants_inventory_extended */
-- SAFE as written (uses only GRANTEE/PRIVILEGE_TYPE, shared across all privilege views).
-- NEEDS CONFIRMATION before reading any per-view object-name column: DESCRIBE each sibling view.
SELECT 'SCHEMA' AS object_scope, PRIVILEGE_TYPE,
       CASE
         WHEN GRANTEE IS NULL OR GRANTEE = '__REDACTED__' THEN GRANTEE
         WHEN GRANTEE LIKE '%@%' THEN concat(substr(GRANTEE, 1, 2), '****@****')
         WHEN GRANTEE RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN GRANTEE
         ELSE concat(substr(GRANTEE, 1, 2), '****')
       END AS GRANTEE,
       COUNT(*) AS grant_count
FROM system.information_schema.schema_privileges GROUP BY 1,2,GRANTEE
UNION ALL
SELECT 'CONNECTION', PRIVILEGE_TYPE,
       CASE
         WHEN GRANTEE IS NULL OR GRANTEE = '__REDACTED__' THEN GRANTEE
         WHEN GRANTEE LIKE '%@%' THEN concat(substr(GRANTEE, 1, 2), '****@****')
         WHEN GRANTEE RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN GRANTEE
         ELSE concat(substr(GRANTEE, 1, 2), '****')
       END,
       COUNT(*)
FROM system.information_schema.connection_privileges GROUP BY 1,2,GRANTEE
UNION ALL
SELECT 'CREDENTIAL', PRIVILEGE_TYPE,
       CASE
         WHEN GRANTEE IS NULL OR GRANTEE = '__REDACTED__' THEN GRANTEE
         WHEN GRANTEE LIKE '%@%' THEN concat(substr(GRANTEE, 1, 2), '****@****')
         WHEN GRANTEE RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN GRANTEE
         ELSE concat(substr(GRANTEE, 1, 2), '****')
       END,
       COUNT(*)
FROM system.information_schema.credential_privileges GROUP BY 1,2,GRANTEE
UNION ALL
SELECT 'EXTERNAL_LOCATION', PRIVILEGE_TYPE,
       CASE
         WHEN GRANTEE IS NULL OR GRANTEE = '__REDACTED__' THEN GRANTEE
         WHEN GRANTEE LIKE '%@%' THEN concat(substr(GRANTEE, 1, 2), '****@****')
         WHEN GRANTEE RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN GRANTEE
         ELSE concat(substr(GRANTEE, 1, 2), '****')
       END,
       COUNT(*)
FROM system.information_schema.external_location_privileges GROUP BY 1,2,GRANTEE
