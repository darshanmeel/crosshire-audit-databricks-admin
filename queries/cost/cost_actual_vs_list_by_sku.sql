-- query_id: cost_actual_vs_list_by_sku
-- source: system.billing.usage JOIN system.billing.account_prices JOIN system.billing.list_prices
-- feeds: actual (negotiated) vs list $ per SKU; negotiated-discount realization %; savings_usd headline on the Pricing & Allocation tab
-- confidence: needs_confirmation
-- caveats: TWO price bases per SKU — negotiated comes from account_prices.pricing.default, list comes from list_prices.pricing.effective_list.default. account_prices has NO effective_list, so we do NOT read effective_list off it. BOTH joins are scoped to the price-row that was ACTIVE on each usage_date: active rows carry price_end_time = NULL, so the window predicate MUST be (price_end_time IS NULL OR usage_date < DATE(price_end_time)) — using only usage_date < DATE(price_end_time) silently zeroes recent usage (the must-fix window bug). Join keys are cloud + currency_code + usage_unit + sku_name, NOT sku_name alone (multi-cloud/multi-currency accounts have several rows per sku_name). Net usage SUMs usage_quantity across ALL record_types (corrections already net out). usage_unit filtered to DBU so we never price storage-bytes/hours/tokens against a per-DBU rate. Both prices are LEFT-joined: a SKU with no matching price row keeps net_dbus but null rates (priced-coverage gap surfaced downstream, never read as $0).
-- NEEDS WORKSPACE CONFIRMATION: list_prices.pricing.effective_list.default and account_prices.pricing.default are documented as object/STRING; the numeric CAST to DOUBLE for both is unverified on this workspace. The downstream finding labels every dollar negotiated/list-unverified and carries it in extra only — never promoted to usd_monthly.
-- NEEDS WORKSPACE CONFIRMATION: currency_code is assumed present and consistent on usage rows; if usage rows carry no currency_code the cloud+usage_unit+sku_name join still binds but multi-currency disambiguation is lost — disclosed, not silently merged.
/* databricks_audit:cost_actual_vs_list_by_sku */
SELECT u.cloud, u.sku_name, u.usage_unit, u.billing_origin_product, u.currency_code,
       SUM(u.usage_quantity)                       AS net_usage_quantity,
       SUM(u.usage_quantity * ap.negotiated_rate)  AS net_negotiated_cost,
       SUM(u.usage_quantity * lp.list_rate)        AS net_list_cost
FROM system.billing.usage u
LEFT JOIN (
  SELECT sku_name, cloud, currency_code, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS negotiated_rate   -- account_prices: pricing.default ONLY (no effective_list)
  FROM system.billing.account_prices
) ap
  ON  u.sku_name      = ap.sku_name
  AND u.cloud         = ap.cloud
  AND u.currency_code = ap.currency_code
  AND u.usage_unit    = ap.usage_unit
  AND u.usage_date    >= DATE(ap.price_start_time)
  AND (ap.price_end_time IS NULL OR u.usage_date < DATE(ap.price_end_time))   -- active rows carry NULL end_time
LEFT JOIN (
  SELECT sku_name, cloud, currency_code, usage_unit, price_start_time, price_end_time,
         CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- list_prices: effective_list.default
  FROM system.billing.list_prices
) lp
  ON  u.sku_name      = lp.sku_name
  AND u.cloud         = lp.cloud
  AND u.currency_code = lp.currency_code
  AND u.usage_unit    = lp.usage_unit
  AND u.usage_date    >= DATE(lp.price_start_time)
  AND (lp.price_end_time IS NULL OR u.usage_date < DATE(lp.price_end_time))   -- same active-row predicate
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
  AND upper(u.usage_unit) = 'DBU'   -- price only DBU rows against a per-DBU rate; never blend bytes/hours/tokens
GROUP BY u.cloud, u.sku_name, u.usage_unit, u.billing_origin_product, u.currency_code
