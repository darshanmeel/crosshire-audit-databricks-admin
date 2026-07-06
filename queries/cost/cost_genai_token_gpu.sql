-- query_id: cost_genai_token_gpu
-- source: system.billing.usage
-- feeds: GenAI/token spend (usage_type TOKEN/GPU_TIME); model-serving cost attribution; AI-cost anomaly detection
-- confidence: confirmed
-- caveats: Confirmed usage_type enum: COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTE, NETWORK_HOUR, API_OPERATION, TOKEN, GPU_TIME, ANSWER. usage_unit varies by usage_type — TOKEN/GPU rows are NOT DBU-denominated; price each via its own list_prices SKU row, never the DBU rate. usage_metadata endpoint fields populate only for model-serving / vector-search.
/* databricks_audit:cost_genai_token_gpu */
SELECT usage_date, cloud, sku_name, billing_origin_product, usage_type, usage_unit,
       product_features.serving_type  AS serving_type,
       CASE WHEN usage_metadata.endpoint_name IS NULL THEN usage_metadata.endpoint_name ELSE concat(substr(usage_metadata.endpoint_name, 1, 2), '****') END AS endpoint_name,
       usage_metadata.endpoint_id     AS endpoint_id,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_type IN ('TOKEN', 'GPU_TIME', 'ANSWER')
GROUP BY usage_date, cloud, sku_name, billing_origin_product, usage_type, usage_unit,
         product_features.serving_type, usage_metadata.endpoint_name, usage_metadata.endpoint_id
