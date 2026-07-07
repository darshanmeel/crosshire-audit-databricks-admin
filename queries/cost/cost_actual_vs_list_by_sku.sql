-- query_id: cost_actual_vs_list_by_sku
-- title: Actual vs list price by SKU (discount realization)
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.list_prices are generally available)
-- params: :period_days (default 30) rolling window in days; :warn_realization_ratio (default 0.75) share of list price you are estimated to actually pay that flags WARN; :crit_realization_ratio (default 0.90) share of list price you are estimated to actually pay that flags CRITICAL - field heuristic; tune both for your account's negotiated commit
-- confidence: needs_confirmation
-- confidence_note: There is no system.billing.account_prices table in this environment, so both the "actual/default" and "list" rates are approximated from system.billing.list_prices (pricing.default and pricing.effective_list.default respectively); treat every dollar here as default/list-unverified, not a confirmed negotiated rate.
-- read_this: One row = a cloud + SKU + usage_unit's DBU spend for the window, priced two ways. The columns that matter are net_default_cost (what you are estimated to actually pay) and net_list_cost (undiscounted list price) - the smaller the gap between them, the less discount you are realizing on that SKU.
-- healthy: net_default_cost stays well below net_list_cost - i.e. the realization ratio (net_default_cost / net_list_cost) is under :warn_realization_ratio (field heuristic; tune for your account's commit).
-- investigate_if: realization ratio at/above :warn_realization_ratio (WARN) or :crit_realization_ratio (CRITICAL) - you are paying close to list price on that SKU; or either cost column is NULL (NOT_ASSESSED - a priced-coverage gap, not $0).
-- actions: 1) confirm the SKU actually needs its current tier/edition before assuming a pricing problem (free); 2) route the workload to a discounted commitment tier or a cheaper SKU family for that workload (config); 3) escalate the SKU to your Databricks account team for a better negotiated rate (spend).
-- next: cost_dollarized_by_sku_day (for the full dollarized cost series across all SKUs), cost_account_prices_raw (for the underlying raw price rows behind this comparison)
-- caveats: Two price bases per SKU, both from list_prices - the "default/effective" rate is list_prices.pricing.default, the "list" rate is list_prices.pricing.effective_list.default. There is no account_prices/negotiated-rate table in this environment, so a true negotiated rate is unavailable and is approximated by pricing.default; every dollar here is default/list-unverified. Both joins are scoped to the price row that was active on each usage_date: active rows carry price_end_time = NULL, so the window predicate is (price_end_time IS NULL OR usage_date < DATE(price_end_time)) - using only usage_date < DATE(price_end_time) would silently zero out recent usage. Join keys are cloud + usage_unit + sku_name, not sku_name alone (multi-cloud accounts have several rows per sku_name). currency_code is not a column on system.billing.usage, so it cannot drive the join; multi-currency accounts may match more than one list_prices currency row and that is not disambiguated here. net_usage_quantity sums usage_quantity across all record_types (corrections already net out). usage_unit is filtered to DBU so storage-bytes/hours/tokens are never priced against a per-DBU rate. Both prices are LEFT-joined: a SKU with no matching price row keeps net_dbus but null cost columns - read that as a priced-coverage gap, never as $0.
SELECT u.cloud, u.sku_name, u.usage_unit, u.billing_origin_product,
       SUM(u.usage_quantity)                       AS net_usage_quantity,
       SUM(u.usage_quantity * dp.default_rate)     AS net_default_cost,
       SUM(u.usage_quantity * lp.list_rate)        AS net_list_cost,
       -- status: discount-realization band on default-cost / list-cost (field heuristic; :warn_realization_ratio / :crit_realization_ratio).
       CASE
         WHEN SUM(u.usage_quantity * dp.default_rate) IS NULL OR SUM(u.usage_quantity * lp.list_rate) IS NULL THEN 'NOT_ASSESSED'
         WHEN (SUM(u.usage_quantity * dp.default_rate) / NULLIF(SUM(u.usage_quantity * lp.list_rate), 0)) >= :crit_realization_ratio THEN 'CRITICAL'
         WHEN (SUM(u.usage_quantity * dp.default_rate) / NULLIF(SUM(u.usage_quantity * lp.list_rate), 0)) >= :warn_realization_ratio THEN 'WARN'
         ELSE 'OK'
       END AS status
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
ORDER BY (SUM(u.usage_quantity * dp.default_rate) / NULLIF(SUM(u.usage_quantity * lp.list_rate), 0)) DESC NULLS LAST, net_list_cost DESC
