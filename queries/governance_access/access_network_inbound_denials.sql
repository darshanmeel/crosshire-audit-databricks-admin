-- query_id: access_network_inbound_denials
-- source: system.access.inbound_network
-- feeds: network denials
-- confidence: needs_confirmation — verifier status unverifiable
-- NEEDS WORKSPACE CONFIRMATION: the nested subfield source.ip. The doc says the source struct "subfields include ip, private-link" but "include" is non-exhaustive and the exact identifier (ip vs ip_address; private-link may need backticks) is not transcribed verbatim. All other columns (policy_outcome, rule_label, request_path, authenticated_as, event_time) are confirmed. A wrong name errors the whole statement — make it defensive (drop or replace with the verified subfield).
-- caveats: DENIALS ONLY. policy_outcome DENY/DENY_DRY_RUN. Inbound retention = 30 DAYS (look-back capped at 30d regardless of period_days). Uses event_time (no event_date column). Empty if no ingress policy configured. Preview. Regional.
/* databricks_audit:access_network_inbound_denials */
-- NEEDS CONFIRMATION: source.ip nested subfield name is UNVERIFIED. A wrong name errors the
-- whole statement — make it defensive (drop or replace with the verified subfield).
SELECT policy_outcome, rule_label, request_path,
       CASE
         WHEN authenticated_as IS NULL OR authenticated_as = '__REDACTED__' THEN authenticated_as
         WHEN authenticated_as LIKE '%@%' THEN concat(substr(authenticated_as, 1, 2), '****@****')
         WHEN authenticated_as RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN authenticated_as
         ELSE concat(substr(authenticated_as, 1, 2), '****')
       END AS authenticated_as,
       source.ip AS source_ip,
       COUNT(*) AS denial_count,
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
FROM system.access.inbound_network
WHERE event_time >= current_timestamp() - INTERVAL 30 DAYS
GROUP BY 1, 2, 3, authenticated_as, 5
