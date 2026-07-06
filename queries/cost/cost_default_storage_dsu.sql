-- query_id: cost_default_storage_dsu
-- source: system.billing.usage
-- feeds: DEFAULT_STORAGE/DSU storage cost; Default-storage TIER_1 vs TIER_2 API operations (storage_api_type)
-- confidence: needs_confirmation — verifier status `unverifiable`
-- NEEDS WORKSPACE CONFIRMATION: the filter value billing_origin_product = 'DEFAULT_STORAGE'. The doc states billing_origin_product has NO published closed enum ("do not hardcode an enum"); the 'DEFAULT_STORAGE' string comes from the implementation plan, not an enumerated doc list. The columns storage_api_type and catalog_id themselves ARE confirmed. Safer fallback (used as primary below): filter by usage_metadata.storage_api_type IS NOT NULL (a confirmed default-storage signal) so default-storage rows are captured even if the literal differs on the workspace.
-- caveats: metastore_id (the other default-storage key) is AWS-only — null on Azure/GCP — and intentionally omitted; add per-cloud if needed. Treat the most recent day's usage_quantity as provisional (billing populate lag).
/* databricks_audit:cost_default_storage_dsu */
-- NEEDS CONFIRMATION: billing_origin_product = 'DEFAULT_STORAGE' literal is UNVERIFIED.
-- Using the confirmed signal as the primary filter: WHERE usage_metadata.storage_api_type IS NOT NULL
SELECT usage_date, cloud, sku_name, usage_type, usage_unit,
       usage_metadata.storage_api_type AS storage_api_type,
       usage_metadata.catalog_id       AS catalog_id,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_metadata.storage_api_type IS NOT NULL   -- confirmed default-storage signal (safer fallback)
GROUP BY usage_date, cloud, sku_name, usage_type, usage_unit,
         usage_metadata.storage_api_type, usage_metadata.catalog_id
