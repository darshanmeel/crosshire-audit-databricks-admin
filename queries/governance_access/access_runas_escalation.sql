-- query_id: access_runas_escalation
-- title: Run-as escalation: initiator vs executed-as identity
-- domain: governance_access   tier: deep
-- reads: system.access.audit
-- requires: SELECT on system.access; Public Preview
-- params: :period_days (default 30) rolling window in days; :warn_runas_events (default 5) run_by != run_as events for one identity pair in the window that flags WARN; :crit_runas_events (default 25) that flags CRITICAL
-- confidence: confirmed
-- confidence_note: identity_metadata.run_by and run_as are read directly off system.access.audit; no inferred column names here.
-- read_this: One row = a masked run_by/run_as identity pair x service x action, where the principal that initiated an action (run_by) differs from the identity it executed as (run_as). The column that matters is event_count - how often that specific pair fired in the window.
-- healthy: status = OK; event_count below :warn_runas_events for one run_by/run_as pair - field heuristic; a low, steady count is often a legitimate job running as a service principal.
-- investigate_if: status = WARN at/above :warn_runas_events, CRITICAL at/above :crit_runas_events - field heuristic; also treat a ZERO-ROW result with suspicion rather than relief - see caveats.
-- actions: 1) confirm whether the run_as identity is a known service principal configured for that job/pipeline (free); 2) if unexpected, revoke the run_by principal's ability to act as that identity and review its grants via access_grants_inventory (config); 3) if run-as patterns are hard to reason about at scale, invest in a naming/tagging convention for service principals so legitimate run-as pairs are self-documenting (spend/eng time).
-- next: access_admin_role_change_events (check if the same run_by identity also touched admin roles), access_grants_inventory (see what the run_as identity can do)
-- caveats: identity_metadata is commonly NULL for ordinary single-user actions, so expect it to be sparse or entirely empty on many accounts - an empty result here means "not assessed", not "no escalation happened". Before trusting a clean (zero-row) result, verify system.access.audit is actually populated for your account and window. This reads system.access.audit, which is Public Preview.
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
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time,
       -- status: worst-first band on run-by != run-as event volume per identity pair (field heuristic; :warn_runas_events / :crit_runas_events). Zero rows does not mean OK - see caveats.
       CASE
         WHEN COUNT(*) >= :crit_runas_events THEN 'CRITICAL'
         WHEN COUNT(*) >= :warn_runas_events THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.access.audit
WHERE identity_metadata.run_by IS NOT NULL
  AND identity_metadata.run_as IS NOT NULL
  AND identity_metadata.run_by <> identity_metadata.run_as
  AND event_date >= current_date() - INTERVAL :period_days DAYS
  AND event_date < current_date()
GROUP BY 1, 2, identity_metadata.run_by, identity_metadata.run_as
ORDER BY event_count DESC
