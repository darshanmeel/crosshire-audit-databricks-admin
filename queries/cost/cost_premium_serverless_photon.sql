-- query_id: cost_premium_serverless_photon
-- source: system.billing.usage
-- feeds: serverless-vs-classic / Photon premium; DLT/Lakeflow pipeline tier optimization (dlt_tier); perf-optimized serverless premium (performance_target)
-- confidence: confirmed
-- caveats: product_features is sparse — subfields null where the serverless/classic/Photon/tier choice is unavailable; non-serverless workloads have performance_target = null. is_photon can be cross-checked via sku_name LIKE '%(PHOTON)%' (a string-pattern heuristic from the findings spec). Pair with list_prices to dollarize the premium delta in-engine.
/* databricks_audit:cost_premium_serverless_photon */
SELECT usage_date, cloud, sku_name, billing_origin_product,
       product_features.is_serverless      AS is_serverless,
       product_features.is_photon          AS is_photon,
       product_features.jobs_tier          AS jobs_tier,
       product_features.sql_tier           AS sql_tier,
       product_features.dlt_tier           AS dlt_tier,
       product_features.performance_target AS performance_target,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, sku_name, billing_origin_product,
         product_features.is_serverless, product_features.is_photon, product_features.jobs_tier,
         product_features.sql_tier, product_features.dlt_tier, product_features.performance_target
