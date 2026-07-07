-- query_id: cost_dollarized_by_sku_day
-- title: Dollarized cost by SKU and day (list price)
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.list_prices are generally available)
-- params: :period_days (default 30) rolling window in days
-- confidence: needs_confirmation
-- confidence_note: The nested path list_prices.pricing.effective_list.default is not confirmed as a numerically castable scalar (the schema only types pricing.effective_list as an object); until confirmed, treat net_list_cost as directional and prefer dollarizing from pricing_list_prices_raw instead.
-- read_this: One row = a day + cloud + SKU + product + usage type/unit's usage, priced at list. The columns that matter are net_usage_quantity (the native-unit volume) and net_list_cost (usage_quantity x the list rate) - this is a pre-discount estimate, not what you actually pay.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: pricing_list_prices_raw (for the raw price rows behind net_list_cost, safer to dollarize from until the effective_list.default path is confirmed), cost_actual_vs_list_by_sku (for a DBU-only actual-vs-list comparison)
-- caveats: This is a list price only - pre-discount - so apply any negotiated discount factor yourself; net_list_cost is dollarized so it is safe to sum even though the underlying usage spans several usage_type/usage_unit families. The price window is open-interval: price_end_time NULL means the currently effective price. The path list_prices.pricing.effective_list.default that this query casts to DOUBLE is not confirmed - the schema only documents pricing.effective_list as an object, not this nested scalar - and pricing.default is typed STRING, so any DOUBLE cast of it is likewise unconfirmed. Until that path is confirmed on your workspace, prefer collecting the raw list_prices artifact (pricing_list_prices_raw) and dollarizing it yourself rather than trusting net_list_cost as-is.
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
ORDER BY u.usage_date DESC, u.cloud, u.sku_name
