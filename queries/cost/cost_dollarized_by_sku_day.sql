-- query_id: cost_dollarized_by_sku_day
-- source: system.billing.usage JOIN system.billing.list_prices
-- feeds: cost totals (dollarized); dollarization (list-price × discount_factor); credit/usage anomalies (dollar series); chargeback dollar rollups
-- confidence: needs_confirmation — verifier status unverifiable
-- NEEDS WORKSPACE CONFIRMATION: list_prices.pricing.effective_list.default — the doc types pricing.effective_list only as an "object"; it does NOT confirm a nested scalar subfield path pricing.effective_list.default nor that it is numerically CAST-able to DOUBLE. pricing.default is typed STRING, so any DOUBLE cast of it is likewise unconfirmed. Until confirmed, dollarize in-engine off pricing_list_prices_raw (raw JSON) instead.
-- caveats: LIST price only — pre-discount, DBU-only, excludes cloud infra/egress; engine applies discount_factor downstream. Open-interval price window: price_end_time NULL = currently effective. Until the effective_list.default path is confirmed on the workspace, collect the raw list_prices artifact (pricing_list_prices_raw) and dollarize in-engine rather than trusting net_list_cost.
/* databricks_audit:cost_dollarized_by_sku_day */
-- NEEDS CONFIRMATION: list_rate path pricing.effective_list.default is UNVERIFIED.
-- Until confirmed, dollarize in-engine off pricing_list_prices_raw (raw JSON) instead.
SELECT u.usage_date, u.cloud, u.sku_name, u.billing_origin_product, u.usage_type, u.usage_unit,
       lp.currency_code,
       SUM(u.usage_quantity)               AS net_usage_quantity,
       SUM(u.usage_quantity * lp.list_rate) AS net_list_cost
FROM system.billing.usage u
LEFT JOIN (
  SELECT sku_name, cloud, currency_code, usage_unit, price_start_time, price_end_time,
         CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- <-- UNVERIFIED path
  FROM system.billing.list_prices
) lp
  ON u.sku_name = lp.sku_name
 AND u.cloud    = lp.cloud
 AND u.usage_end_time >= lp.price_start_time
 AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
GROUP BY u.usage_date, u.cloud, u.sku_name, u.billing_origin_product, u.usage_type, u.usage_unit, lp.currency_code
