-- query_id: cost_networking_egress
-- title: Networking / egress usage
-- domain: cost   tier: standard
-- reads: system.billing.usage
-- requires: SELECT on system.billing; GA (system.billing.usage is generally available)
-- params: :period_days (default 30) rolling window in days
-- confidence: confirmed
-- confidence_note: usage_metadata.{source_region, destination_region, networking_client, recipient_id} are documented system.billing.usage columns.
-- read_this: One row = a day + cloud + SKU + usage type's billed networking usage. The columns that matter are usage_type (NETWORK_BYTE vs NETWORK_HOUR are different units) and net_usage_quantity - this is the closest billed-egress signal available, not a full network cost reconciliation.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: cost_cloud_infra (for the broader DBU-derived cloud cost estimate), cost_by_billing_origin_product (for total usage by product line in the same window)
-- caveats: source_region / destination_region are always NULL on GCP - do not read a GCP null as "no egress." These are the closest billed-egress signal, but egress is largely cloud-side; a real reconciliation needs your cloud provider's own cost export. usage_unit here is bytes/hours, not DBU - do not price it at the DBU rate.
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
ORDER BY usage_date DESC, cloud, usage_type
