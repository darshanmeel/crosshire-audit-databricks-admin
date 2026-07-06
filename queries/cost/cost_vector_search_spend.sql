-- query_id: cost_vector_search_spend
-- source: system.billing.usage JOIN system.billing.list_prices
-- feeds: Vector Search spend by endpoint (serving vs ingest vs DSU storage); idle-endpoint opportunity (joined to access_vector_search_traffic in-engine)
-- confidence: confirmed (billing columns) — list_rate path needs_confirmation
-- caveats: billing_origin_product='VECTOR_SEARCH', usage_metadata.endpoint_name (AI Search endpoint), and usage_type enum (STORAGE_SPACE = DSU storage, else serving DBUs) are CONFIRMED in docs (system-tables/billing + vector-search cost-management). STORAGE_SPACE rows are DSU-denominated, serving rows are DBU-denominated — different units, never summed. net_list_cost rides the SAME UNVERIFIED list_prices.pricing.effective_list.default path as cost_dollarized_by_sku_day — LIST/pre-discount only, the engine applies ctx.dbu_discount downstream and never promotes it to a billed headline. Open-interval price window: price_end_time NULL = currently effective.
/* databricks_audit:cost_vector_search_spend */
SELECT u.usage_date, u.cloud, u.sku_name, u.usage_type, u.usage_unit,
       CASE WHEN u.usage_metadata.endpoint_name IS NULL THEN u.usage_metadata.endpoint_name ELSE concat(substr(u.usage_metadata.endpoint_name, 1, 2), '****') END AS endpoint_name,
       u.usage_metadata.endpoint_id   AS endpoint_id,
       lp.currency_code,
       SUM(u.usage_quantity)                AS net_usage_quantity,
       SUM(u.usage_quantity * lp.list_rate) AS net_list_cost
FROM system.billing.usage u
LEFT JOIN (
  SELECT sku_name, cloud, currency_code, price_start_time, price_end_time,
         CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- <-- UNVERIFIED path (same caveat as cost_dollarized_by_sku_day)
  FROM system.billing.list_prices
) lp
  ON u.sku_name = lp.sku_name
 AND u.cloud    = lp.cloud
 AND u.usage_end_time >= lp.price_start_time
 AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
WHERE u.billing_origin_product = 'VECTOR_SEARCH'
  AND u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
GROUP BY u.usage_date, u.cloud, u.sku_name, u.usage_type, u.usage_unit,
         u.usage_metadata.endpoint_name, u.usage_metadata.endpoint_id, lp.currency_code
