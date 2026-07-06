-- query_id: access_runas_escalation
-- source: system.access.audit
-- feeds: run-as escalation
-- confidence: confirmed
-- caveats: identity_metadata is commonly NULL for ordinary single-user actions — expect sparse/empty on many accounts; empty != no escalation (degrade to "not assessed" if no rows AND verify the table is populated). Preview table.
/* databricks_audit:access_runas_escalation */
SELECT service_name, action_name,
       CASE
         WHEN identity_metadata.run_by IS NULL OR identity_metadata.run_by = '__REDACTED__' THEN identity_metadata.run_by
         WHEN identity_metadata.run_by LIKE '%@%' THEN concat(substr(identity_metadata.run_by, 1, 2), '****@****')
         WHEN identity_metadata.run_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN identity_metadata.run_by
         ELSE concat(substr(identity_metadata.run_by, 1, 2), '****')
       END AS run_by,
       CASE
         WHEN identity_metadata.run_as IS NULL OR identity_metadata.run_as = '__REDACTED__' THEN identity_metadata.run_as
         WHEN identity_metadata.run_as LIKE '%@%' THEN concat(substr(identity_metadata.run_as, 1, 2), '****@****')
         WHEN identity_metadata.run_as RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN identity_metadata.run_as
         ELSE concat(substr(identity_metadata.run_as, 1, 2), '****')
       END AS run_as,
       COUNT(*) AS event_count,
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
FROM system.access.audit
WHERE identity_metadata.run_by IS NOT NULL
  AND identity_metadata.run_as IS NOT NULL
  AND identity_metadata.run_by <> identity_metadata.run_as
  AND event_date >= current_date() - INTERVAL 30 DAYS
  AND event_date < current_date()
GROUP BY 1, 2, identity_metadata.run_by, identity_metadata.run_as
