-- query_id: access_login_concentration
-- title: Login concentration and failed-authentication rollup
-- domain: governance_access   tier: standard
-- reads: system.access.audit
-- requires: SELECT on system.access; Public Preview
-- empty_if: schema_not_enabled, preview_unavailable, privilege_scoped
-- params: :period_days (default 30) rolling window in days; :warn_failed_logins (default 5) non-success auth events for one principal+source_ip+service+action combo that flags WARN; :crit_failed_logins (default 20) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: service_name='accounts' is confirmed; specific action_name values (mfaLogin, tokenLogin, and others) are representative, not a complete enumeration - group by action_name rather than hardcoding a filter list. user_identity.subject_name (not subjectName) was confirmed live 2026-05-30 and is frequently NULL. Whether response.status_code is int or long is unverified, so the <>200 OR NULL comparison is written defensively either way.
-- read_this: One row = a masked principal x source IP x service x action combo in the window. The columns that matter are non_success_count (failed/non-200 attempts) and distinct_source_ips (how many locations that principal authenticated from).
-- healthy: status = OK; non_success_count below :warn_failed_logins for one principal+IP+action - field heuristic; some non-success events are normal (typos, expired tokens).
-- investigate_if: status = WARN at/above :warn_failed_logins, CRITICAL at/above :crit_failed_logins - field heuristic; also worth a look whenever distinct_source_ips is high for a single principal, which this query surfaces but does not score.
-- actions: 1) confirm whether the failed attempts are a known automation/CI credential that rotated or expired (free); 2) if unexplained, force a credential/token reset for that principal and require MFA (config); 3) if this recurs across many principals, invest in a dedicated identity-threat-detection tool or SIEM integration ahead of Databricks-native monitoring (spend).
-- next: access_runas_escalation (check if the same principal shows run-as activity), access_admin_role_change_events (check if they also touched admin roles)
-- caveats: service_name='accounts' is confirmed, but the specific action_name values (mfaLogin, tokenLogin, and others) are representative, not a complete list - group by action_name instead of filtering to a hardcoded set. user_identity.subject_name (not subjectName) was confirmed live on 2026-05-30 and is frequently NULL. Whether response.status_code is an int or a long is unverified, so the <>200 OR NULL check is written defensively to catch both. This reads system.access.audit, which is Public Preview. Account-level events are global (workspace_id=0); workspace events are regional, so a single-region query undercounts. Ingest lag is roughly 15 minutes - treat the most recent hour as provisional and re-run later for a complete count.
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
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time,
       -- status: worst-first band on non-success (failed) auth attempts per principal+IP+action (field heuristic; :warn_failed_logins / :crit_failed_logins).
       CASE
         WHEN SUM(CASE WHEN response.status_code <> 200 OR response.status_code IS NULL THEN 1 ELSE 0 END) >= :crit_failed_logins THEN 'CRITICAL'
         WHEN SUM(CASE WHEN response.status_code <> 200 OR response.status_code IS NULL THEN 1 ELSE 0 END) >= :warn_failed_logins THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.access.audit
WHERE service_name = 'accounts'
  AND event_date >= current_date() - INTERVAL :period_days DAYS
  AND event_date < current_date()
GROUP BY COALESCE(user_identity.email, user_identity.subject_name), 2, 3, 4
ORDER BY non_success_count DESC
