-- query_id: pricing_list_prices_raw
-- source: system.billing.list_prices
-- feeds: dollarization (list-price × discount_factor); cost totals; per-SKU rate basis for the aggregator (replaces the hardcoded $0.55/DBU)
-- confidence: confirmed
-- caveats: Small table (one row per SKU price change) — collect raw, no aggregation, so the engine picks the right [price_start_time, price_end_time) window per usage row itself and survives pricing-struct drift. effective_list / promotional are serialized to JSON strings so collection never breaks if their internal shape changes; the engine parses defensively. price_end_time NULL = current price. (pricing.default is typed STRING in the doc — confirm numeric castability before using it for arithmetic; see checklist.)
/* databricks_audit:pricing_list_prices_raw */
SELECT price_start_time, price_end_time, account_id, sku_name, cloud, currency_code, usage_unit,
       CAST(pricing.default       AS STRING) AS pricing_default,
       CAST(pricing.effective_list AS STRING) AS pricing_effective_list_json,
       CAST(pricing.promotional   AS STRING) AS pricing_promotional_json
FROM system.billing.list_prices
