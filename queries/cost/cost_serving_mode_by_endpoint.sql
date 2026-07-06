-- query_id: cost_serving_mode_by_endpoint
-- source: system.billing.usage JOIN system.billing.list_prices
-- feeds: cost_serving_cost_mode_efficiency (gov-7) — per-endpoint model-serving spend with inferred cost mode (pay-per-token vs provisioned vs scale-from-zero LAUNCH) + bounded list cost for dollarization
-- confidence: confirmed (column paths verified against docs.databricks.com 2026-06-21), EXCEPT the list_rate path (see caveats)
-- caveats: All BILLING columns are doc-confirmed: billing_origin_product='MODEL_SERVING'; product_features.serving_type enum {MODEL,GPU_MODEL,FOUNDATION_MODEL,FEATURE,null}; usage_type enum incl COMPUTE_TIME/GPU_TIME/TOKEN/ANSWER; usage_metadata.endpoint_name/endpoint_id; SKU '%SERVERLESS_REAL_TIME_INFERENCE_LAUNCH%' = scale-from-zero cold-start launches per the model-serving-cost monitoring page. COST MODE IS INFERRED from these billed signals, NOT read from a config column: Databricks does NOT expose workload_type/workload_size/scale_to_zero_enabled in system.serving.served_entities (those are serving-endpoints API fields only). UNVERIFIED path: list_rate via pricing.effective_list.default (doc types pricing.effective_list only as 'object') — SAME caveat as cost_dollarized_by_sku_day; net_list_cost is NULL when the path/join is absent and the finding degrades dollarization to 'list cost unavailable', never inventing a rate. Empty result = model serving not in use in the window (a real result, not $0).
/* databricks_audit:cost_serving_mode_by_endpoint */
SELECT
  u.usage_metadata.endpoint_id           AS endpoint_id,
  CASE WHEN u.usage_metadata.endpoint_name IS NULL THEN u.usage_metadata.endpoint_name ELSE concat(substr(u.usage_metadata.endpoint_name, 1, 2), '****') END AS endpoint_name,
  u.cloud                                AS cloud,
  u.sku_name                             AS sku_name,
  u.usage_type                           AS usage_type,
  u.usage_unit                           AS usage_unit,
  u.product_features.serving_type        AS serving_type,
  CASE WHEN upper(u.sku_name) LIKE '%SERVERLESS_REAL_TIME_INFERENCE_LAUNCH%'
       THEN TRUE ELSE FALSE END          AS is_launch_sku,
  SUM(u.usage_quantity)                  AS net_usage_quantity,
  SUM(u.usage_quantity * lp.list_rate)   AS net_list_cost
FROM system.billing.usage u
LEFT JOIN (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- UNVERIFIED path; see caveats
  FROM system.billing.list_prices
) lp
  ON  u.sku_name = lp.sku_name
  AND u.cloud    = lp.cloud
  AND u.usage_end_time >= lp.price_start_time
  AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date <  current_date()
  AND u.billing_origin_product = 'MODEL_SERVING'
GROUP BY
  u.usage_metadata.endpoint_id,
  u.usage_metadata.endpoint_name,
  u.cloud,
  u.sku_name,
  u.usage_type,
  u.usage_unit,
  u.product_features.serving_type,
  CASE WHEN upper(u.sku_name) LIKE '%SERVERLESS_REAL_TIME_INFERENCE_LAUNCH%' THEN TRUE ELSE FALSE END
