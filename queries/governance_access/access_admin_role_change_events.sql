-- query_id: access_admin_role_change_events
-- title: Admin and access-control role-change events
-- domain: governance_access   tier: standard
-- reads: system.access.audit
-- requires: SELECT on system.access; Public Preview
-- empty_if: schema_not_enabled, preview_unavailable, privilege_scoped
-- params: :period_days (default 30) rolling window in days; :warn_admin_events (default 20) admin/role-change events by one actor+action in the window that flags WARN; :crit_admin_events (default 100) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: user_identity.subject_name (not subjectName) was confirmed against a live workspace on 2026-05-30.
-- read_this: One row = an actor (masked identity) x service x action combo in the window. The columns that matter are event_count (how often they did it) and distinct_source_ips (how many different locations it came from).
-- healthy: status = OK; event_count below :warn_admin_events per actor/action (field heuristic - tune :warn_admin_events for your account).
-- investigate_if: status = WARN at/above :warn_admin_events, CRITICAL at/above :crit_admin_events - field heuristic; also worth a look whenever distinct_source_ips is unusually high for one actor.
-- actions: 1) confirm the actor and action are expected admin/automation activity and cross-check against your own change log (free); 2) if unexpected, review the actor's current grants via access_grants_inventory and rotate credentials if compromise is suspected (config); 3) if this is a legitimate but noisy automation script, move it to a dedicated service principal with scoped permissions so it stops tripping this alert (spend/eng time).
-- next: access_runas_escalation (if the same actor also shows run-as differences), access_grants_inventory (see what that actor's role change actually granted)
-- caveats: This is a discovery-style rollup of grant/admin change events; pair it with the current-state access_grants_inventory. action_name is representative-not-complete, so treat the group as a whole rather than hardcoding a specific action list (setAdmin, updatePermissions and others may or may not appear, depending on your account). Account-level events are global (workspace_id=0); workspace-level events are regional, so a single-region query will miss activity in other regions. This reads system.access.audit, which is Public Preview. The user_identity struct field is subject_name (confirmed live 2026-05-30), not subjectName. This query historically used a 90-day window; set :period_days=90 to reproduce it.
SELECT service_name, action_name,
       CASE
         WHEN actor IS NULL OR actor = '__REDACTED__' THEN actor
         WHEN actor LIKE '%@%' THEN concat(substr(actor, 1, 2), '****@****')
         WHEN actor RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN actor
         ELSE concat(substr(actor, 1, 2), '****')
       END AS actor,
       event_count, distinct_source_ips, first_event_time, last_event_time,
       -- status: worst-first band on admin/role-change event volume per actor+action (field heuristic; :warn_admin_events / :crit_admin_events).
       CASE
         WHEN event_count >= :crit_admin_events THEN 'CRITICAL'
         WHEN event_count >= :warn_admin_events THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM (
  SELECT service_name, action_name,
         COALESCE(user_identity.email, user_identity.subject_name) AS actor,
         COUNT(*) AS event_count,
         COUNT(DISTINCT source_ip_address) AS distinct_source_ips,
         MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
  FROM system.access.audit
  WHERE service_name IN ('accounts','accountsAccessControl','unityCatalog')
    AND event_date >= current_date() - INTERVAL :period_days DAYS
    AND event_date < current_date()
  GROUP BY 1, 2, 3
)
ORDER BY event_count DESC
