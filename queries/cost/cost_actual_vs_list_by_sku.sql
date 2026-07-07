-- query_id: cost_actual_vs_list_by_sku
-- source: system.billing.usage JOIN system.billing.list_prices (twice) — account_prices does NOT exist in this environment; both rate bases come from list_prices
-- feeds: actual (default) vs list $ per SKU; discount realization %; savings_usd headline on the Pricing & Allocation tab
-- confidence: needs_confirmation
-- caveats: TWO price bases per SKU, BOTH from list_prices — the 'default/effective' rate comes from list_prices.pricing.default, the 'list' rate comes from list_prices.pricing.effective_list.default. There is no account_prices/negotiated-rate table in this environment, so negotiated rates are unavailable and are approximated by pricing.default. BOTH joins are scoped to the price-row that was ACTIVE on each usage_date: active rows carry price_end_time = NULL, so the window predicate MUST be (price_end_time IS NULL OR usage_date < DATE(price_end_time)) — using only usage_date < DATE(price_end_time) silently zeroes recent usage (the must-fix window bug). Join keys are cloud + usage_unit + sku_name, NOT sku_name alone (multi-cloud accounts have several rows per sku_name). currency_code is NOT a column on system.billing.usage, so it cannot drive the join; multi-currency accounts may therefore match multiple list_prices currency rows and must be disambiguated downstream. Net usage SUMs usage_quantity across ALL record_types (corrections already net out). usage_unit filtered to DBU so we never price storage-bytes/hours/tokens against a per-DBU rate. Both prices are LEFT-joined: a SKU with no matching price row keeps net_dbus but null rates (priced-coverage gap surfaced downstream, never read as $0).
-- NEEDS WORKSPACE CONFIRMATION: list_prices.pricing.default and list_prices.pricing.effective_list.default are decimals; the numeric CAST to DOUBLE is a straightforward decimal cast but the downstream finding labels every dollar default/list-unverified and carries it in extra only — never promoted to usd_monthly.
-- NEEDS WORKSPACE CONFIRMATION: system.billing.usage carries no currency_code, so the cloud+usage_unit+sku_name join may bind to more than one currency row on multi-currency accounts — disclosed, not silently merged.
/* databricks_audit:cost_actual_vs_list_by_sku */
SELECT u.cloud, u.sku_name, u.usage_unit, u.billing_origin_product,
       SUM(u.usage_quantity)                       AS net_usage_quantity,
       SUM(u.usage_quantity * dp.default_rate)     AS net_default_cost,
       SUM(u.usage_quantity * lp.list_rate)        AS net_list_cost
FROM system.billing.usage u
LEFT JOIN (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS default_rate   -- list_prices: pricing.default (account_prices does not exist)
  FROM system.billing.list_prices
) dp
  ON  u.sku_name      = dp.sku_name
  AND u.cloud         = dp.cloud
  AND u.usage_unit    = dp.usage_unit
  AND u.usage_date    >= DATE(dp.price_start_time)
  AND (dp.price_end_time IS NULL OR u.usage_date < DATE(dp.price_end_time))   -- active rows carry NULL end_time
LEFT JOIN (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- list_prices: effective_list.default
  FROM system.billing.list_prices
) lp
  ON  u.sku_name      = lp.sku_name
  AND u.cloud         = lp.cloud
  AND u.usage_unit    = lp.usage_unit
  AND u.usage_date    >= DATE(lp.price_start_time)
  AND (lp.price_end_time IS NULL OR u.usage_date < DATE(lp.price_end_time))   -- same active-row predicate
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
  AND upper(u.usage_unit) = 'DBU'   -- price only DBU rows against a per-DBU rate; never blend bytes/hours/tokens
GROUP BY u.cloud, u.sku_name, u.usage_unit, u.billing_origin_product