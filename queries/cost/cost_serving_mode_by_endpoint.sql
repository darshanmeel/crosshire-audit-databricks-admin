-- query_id: cost_serving_mode_by_endpoint
-- title: Model-serving spend by endpoint and inferred cost mode
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.list_prices are generally available)
-- params: :period_days (default 30) rolling window in days; :warn_endpoint_usd_per_day (default 50) estimated list-price $/day on a single endpoint + usage_type that flags WARN; :crit_endpoint_usd_per_day (default 250) $/day that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: The billing columns (billing_origin_product, product_features.serving_type, usage_type, usage_metadata.endpoint_name/endpoint_id, the LAUNCH SKU pattern) are all doc-confirmed; the list_rate path (pricing.effective_list.default) is not, so net_list_cost is a directional estimate, not a confirmed dollar figure.
-- read_this: One row = an endpoint + day + usage_type's model-serving usage with an inferred cost mode. The columns that matter are is_launch_sku (a TRUE-heavy endpoint is repeatedly cold-starting from scale-to-zero, which is itself a cost signal) and net_list_cost (est_usd_list, the estimated dollar exposure that drives the band below).
-- healthy: net_list_cost below :warn_endpoint_usd_per_day est_usd_list/day per endpoint + usage_type (field heuristic - tune for your account).
-- investigate_if: net_list_cost at/above :warn_endpoint_usd_per_day (WARN) or :crit_endpoint_usd_per_day (CRITICAL) est_usd_list/day (field heuristic); or net_list_cost is NULL (NOT_ASSESSED - the list-price join found no matching price row, not $0). A high is_launch_sku share alongside a high band is the strongest signal of scale-to-zero churn.
-- actions: 1) confirm the endpoint's traffic pattern actually needs to scale from zero this often, or whether a minimum-provisioned-throughput floor would be cheaper (free); 2) switch a steadily-busy endpoint from pay-per-token/scale-to-zero to provisioned throughput, or the reverse for a bursty one (config); 3) right-size the endpoint's provisioned capacity or model choice (spend).
-- next: cost_by_serving_endpoint (for the raw, non-dollarized per-endpoint usage split by usage_type), compute_serving_endpoint_cost_status (to check whether a CRITICAL endpoint is actually seeing real traffic)
-- caveats: All billing columns here are doc-confirmed: billing_origin_product='MODEL_SERVING'; product_features.serving_type enum {MODEL, GPU_MODEL, FOUNDATION_MODEL, FEATURE, null}; usage_type enum includes COMPUTE_TIME/GPU_TIME/TOKEN/ANSWER; usage_metadata.endpoint_name/endpoint_id; the SKU pattern '%SERVERLESS_REAL_TIME_INFERENCE_LAUNCH%' identifies scale-from-zero cold-start launches per the model-serving-cost monitoring documentation. The cost mode is inferred from these billed signals, not read from a config column - Databricks does not expose workload_type/workload_size/scale_to_zero_enabled in system tables (those are serving-endpoints API fields only). The list_rate path via pricing.effective_list.default is unverified (the schema only types pricing.effective_list as an object) - the same caveat as cost_dollarized_by_sku_day; net_list_cost is NULL when the path/join is absent, and that degrades to "list cost unavailable," never an invented rate. net_list_cost is an estimate at list price (est_usd_list), never the negotiated/invoice rate. Empty result means model serving is not in use in the window, a real result, not $0.
-- This scopes to billing_origin_product='MODEL_SERVING', so Vector Search endpoint spend (billed separately under VECTOR_SEARCH) is not counted here; feature/function and agent endpoints do bill under MODEL_SERVING and are included. See cost_vector_search_spend for vector-search cost.
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
  SUM(u.usage_quantity * lp.list_rate)   AS net_list_cost,
  -- status: est_usd_list/day band per endpoint + usage_type (field heuristic; :warn_endpoint_usd_per_day / :crit_endpoint_usd_per_day).
  CASE
    WHEN SUM(u.usage_quantity * lp.list_rate) IS NULL THEN 'NOT_ASSESSED'
    WHEN SUM(u.usage_quantity * lp.list_rate) >= :crit_endpoint_usd_per_day THEN 'CRITICAL'
    WHEN SUM(u.usage_quantity * lp.list_rate) >= :warn_endpoint_usd_per_day THEN 'WARN'
    ELSE 'OK'
  END AS status
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
ORDER BY net_list_cost DESC NULLS LAST
