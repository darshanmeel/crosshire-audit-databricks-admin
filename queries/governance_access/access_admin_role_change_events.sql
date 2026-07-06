-- query_id: access_admin_role_change_events
-- source: system.access.audit
-- feeds: admin/role hygiene; access history
-- confidence: confirmed
-- caveats: Discovery-style grant/admin change-event rollup; pairs with the current-state grant inventory. action_name is representative-not-complete (group by it; do not hardcode setAdmin/updatePermissions). Account-level events global (workspace_id=0); workspace events regional. Preview table. user_identity struct field is subject_name (verified live 2026-05-30), not subjectName.
/* databricks_audit:access_admin_role_change_events */
SELECT service_name, action_name,
       CASE
         WHEN actor IS NULL OR actor = '__REDACTED__' THEN actor
         WHEN actor LIKE '%@%' THEN concat(substr(actor, 1, 2), '****@****')
         WHEN actor RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN actor
         ELSE concat(substr(actor, 1, 2), '****')
       END AS actor,
       event_count, distinct_source_ips, first_event_time, last_event_time
FROM (
  SELECT service_name, action_name,
         COALESCE(user_identity.email, user_identity.subject_name) AS actor,
         COUNT(*) AS event_count,
         COUNT(DISTINCT source_ip_address) AS distinct_source_ips,
         MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
  FROM system.access.audit
  WHERE service_name IN ('accounts','accountsAccessControl','unityCatalog')
    AND event_date >= current_date() - INTERVAL 90 DAYS
    AND event_date < current_date()
  GROUP BY 1, 2, 3
)
