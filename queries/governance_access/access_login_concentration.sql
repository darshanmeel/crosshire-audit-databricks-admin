-- query_id: access_login_concentration
-- source: system.access.audit
-- feeds: login concentration; MFA & credentials (events-only); access history
-- confidence: confirmed
-- caveats: service_name='accounts' confirmed; specific action_name values (mfaLogin, tokenLogin, ...) are representative-not-complete — group by action_name, do not hardcode a filter list. user_identity struct field is subject_name (verified live 2026-05-30), not subjectName; frequently NULL. response.status_code int-vs-long type is unverified — the <>200 OR NULL form is defensive. Preview table. Regional for workspace events / global for account events (workspace_id=0). ~15-min ingest lag; treat the most recent hour as provisional.
/* databricks_audit:access_login_concentration */
SELECT CASE
         WHEN COALESCE(user_identity.email, user_identity.subject_name) IS NULL OR COALESCE(user_identity.email, user_identity.subject_name) = '__REDACTED__' THEN COALESCE(user_identity.email, user_identity.subject_name)
         WHEN COALESCE(user_identity.email, user_identity.subject_name) LIKE '%@%' THEN concat(substr(COALESCE(user_identity.email, user_identity.subject_name), 1, 2), '****@****')
         WHEN COALESCE(user_identity.email, user_identity.subject_name) RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN COALESCE(user_identity.email, user_identity.subject_name)
         ELSE concat(substr(COALESCE(user_identity.email, user_identity.subject_name), 1, 2), '****')
       END AS principal,
       source_ip_address, service_name, action_name,
       COUNT(*) AS event_count,
       SUM(CASE WHEN response.status_code = 200 THEN 1 ELSE 0 END) AS success_count,
       SUM(CASE WHEN response.status_code <> 200 OR response.status_code IS NULL THEN 1 ELSE 0 END) AS non_success_count,
       COUNT(DISTINCT source_ip_address) AS distinct_source_ips,
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
FROM system.access.audit
WHERE service_name = 'accounts'
  AND event_date >= current_date() - INTERVAL 30 DAYS
  AND event_date < current_date()
GROUP BY COALESCE(user_identity.email, user_identity.subject_name), 2, 3, 4
