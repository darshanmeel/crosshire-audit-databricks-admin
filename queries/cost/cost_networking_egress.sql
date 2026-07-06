-- query_id: cost_networking_egress
-- source: system.billing.usage
-- feeds: data egress (NETWORK lines); credit/usage anomalies (networking slice); Delta Sharing egress (recipient_id)
-- confidence: confirmed
-- caveats: source_region / destination_region are ALWAYS NULL on GCP — do not read a GCP null as "no egress". These are the closest billed-egress signal but egress is largely cloud-side; reconciliation needs the cloud cost export (degrade accordingly). usage_unit here is bytes/hours, not DBU — do not price at the DBU rate.
/* databricks_audit:cost_networking_egress */
SELECT usage_date, cloud, sku_name, usage_type, usage_unit,
       usage_metadata.source_region      AS source_region,
       usage_metadata.destination_region AS destination_region,
       usage_metadata.networking_client  AS networking_client,
       usage_metadata.recipient_id       AS recipient_id,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_type IN ('NETWORK_BYTE', 'NETWORK_HOUR')
GROUP BY usage_date, cloud, sku_name, usage_type, usage_unit,
         usage_metadata.source_region, usage_metadata.destination_region,
         usage_metadata.networking_client, usage_metadata.recipient_id
