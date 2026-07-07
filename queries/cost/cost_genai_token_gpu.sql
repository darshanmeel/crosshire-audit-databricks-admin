-- query_id: cost_genai_token_gpu
-- title: GenAI token and GPU usage
-- domain: cost   tier: standard
-- reads: system.billing.usage
-- requires: SELECT on system.billing; GA (system.billing.usage is generally available)
-- params: :period_days (default 30) rolling window in days
-- confidence: confirmed
-- confidence_note: The usage_type enum (COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTE, NETWORK_HOUR, API_OPERATION, TOKEN, GPU_TIME, ANSWER) is documented.
-- read_this: One row = a day + cloud + SKU + usage type's GenAI usage. The columns that matter are usage_type (TOKEN vs GPU_TIME vs ANSWER are different units) and net_usage_quantity in that unit - price each usage_type against its own list_prices SKU row, never the DBU rate.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: cost_serving_mode_by_endpoint (for the dollarized, per-endpoint MODEL_SERVING cut), cost_vector_search_spend (for the dollarized VECTOR_SEARCH cut)
-- caveats: The confirmed usage_type enum is COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTE, NETWORK_HOUR, API_OPERATION, TOKEN, GPU_TIME, ANSWER. usage_unit varies by usage_type - TOKEN/GPU rows are not DBU-denominated, so price each via its own list_prices SKU row, never the DBU rate. usage_metadata endpoint fields populate only for model-serving / vector-search. endpoint_name is partial-masked in-SQL (first 2 chars + ****).
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
ORDER BY usage_date DESC, cloud, usage_type
