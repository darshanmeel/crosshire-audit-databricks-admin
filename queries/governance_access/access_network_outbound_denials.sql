-- query_id: access_network_outbound_denials
-- source: system.access.outbound_network
-- feeds: network denials
-- confidence: confirmed
-- caveats: DENIALS ONLY — no allowed-traffic baseline; cannot compute allow/deny ratio. dns_event is NULL unless destination_type=DNS; storage_event NULL unless destination_type=STORAGE. Empty table if no egress policy -> "not assessed — no egress policy / preview not populated", NOT zero exfiltration. Uses event_time (no event_date column on this table). Outbound retention 365d. Regional.
/* databricks_audit:access_network_outbound_denials */
SELECT network_source_type, destination_type, access_type, destination,
       dns_event.rcode                AS dns_rcode,
       storage_event.rejection_reason AS storage_rejection_reason,
       COUNT(*) AS denial_count,
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
FROM system.access.outbound_network
WHERE event_time >= current_timestamp() - INTERVAL 30 DAYS
GROUP BY 1, 2, 3, 4, 5, 6
