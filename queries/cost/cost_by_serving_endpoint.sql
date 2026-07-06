-- query_id: cost_by_serving_endpoint
-- source: system.billing.usage (usage_metadata.endpoint_id / endpoint_name)
-- feeds: per-ENDPOINT model-serving + vector-search DBU cost & daily trend -> SIZES the 64% MODEL_SERVING + 14% VECTOR_SEARCH bill (78% of spend) by endpoint, so the biggest / fastest-growing endpoints can be right-sized first; per-workspace serving cost
-- confidence: confirmed (usage_metadata.endpoint_id/endpoint_name doc-confirmed for MODEL_SERVING; same paths as cost_serving_mode_by_endpoint)
-- caveats: this sizes the SPEND per endpoint — the right-sizing config (scale-to-zero, provisioned vs used throughput) is NOT in any system table (serving-endpoints API only), so this is the "where the 78% goes" map, not the fix itself. usage_quantity is DBU, not dollars. usage_type separates COMPUTE_TIME / GPU_TIME / TOKEN. Empty result = serving/vector not in use in the window (a real result, not $0).
/* databricks_audit:cost_by_serving_endpoint */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.endpoint_id AS endpoint_id,
       CASE WHEN usage_metadata.endpoint_name IS NULL THEN usage_metadata.endpoint_name
            ELSE concat(substr(usage_metadata.endpoint_name, 1, 2), '****') END AS endpoint_name,
       usage_type,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_unit = 'DBU'
  AND billing_origin_product IN ('MODEL_SERVING', 'VECTOR_SEARCH')
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         usage_metadata.endpoint_id, usage_metadata.endpoint_name, usage_type
