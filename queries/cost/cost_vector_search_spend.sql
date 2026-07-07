-- query_id: cost_vector_search_spend
-- title: Vector Search spend by endpoint
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.list_prices are generally available)
-- params: :period_days (default 30) rolling window in days; :warn_endpoint_usd_per_day (default 25) estimated list-price $/day on a single Vector Search endpoint that flags WARN; :crit_endpoint_usd_per_day (default 100) $/day that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: billing_origin_product='VECTOR_SEARCH', usage_metadata.endpoint_name, and the usage_type enum are confirmed in docs; the list_rate path (pricing.effective_list.default) is not, so net_list_cost is a directional estimate.
-- read_this: One row = a Vector Search endpoint + day + usage type's spend. The columns that matter are usage_type (STORAGE_SPACE is DSU storage, everything else is serving DBUs - different units) and net_list_cost (est_usd_list, the dollarized driver behind the band, which is safe to compare across usage_type because it is already in dollars).
-- healthy: net_list_cost below :warn_endpoint_usd_per_day est_usd_list/day per endpoint (field heuristic - tune for your account).
-- investigate_if: net_list_cost at/above :warn_endpoint_usd_per_day (WARN) or :crit_endpoint_usd_per_day (CRITICAL) est_usd_list/day (field heuristic); or net_list_cost is NULL (NOT_ASSESSED - the list-price join found no matching price row, not $0).
-- actions: 1) confirm the endpoint's index is still queried by something (free) - cross-check against real traffic before assuming it is idle; 2) shrink or consolidate an oversized/underused index, or right-size its DSU tier (config); 3) if traffic genuinely justifies the spend, budget for it deliberately (spend).
-- next: cost_by_serving_endpoint (for the raw, non-dollarized MODEL_SERVING + VECTOR_SEARCH usage), compute_serving_endpoint_cost_status (to check whether a CRITICAL endpoint is actually receiving traffic before you shrink it)
-- caveats: billing_origin_product='VECTOR_SEARCH', usage_metadata.endpoint_name (the Vector Search endpoint), and the usage_type enum (STORAGE_SPACE = DSU storage, everything else = serving DBUs) are confirmed in the billing and vector-search cost-management documentation. STORAGE_SPACE rows are DSU-denominated and serving rows are DBU-denominated - different units, never summed directly; net_list_cost dollarizes both onto the same $ scale, which is why it (not net_usage_quantity) drives the band. net_list_cost rides the same unverified list_prices.pricing.effective_list.default path as cost_dollarized_by_sku_day - this is a list/pre-discount estimate (est_usd_list); apply your own discount factor and never promote it to a billed headline. The price window is open-interval: price_end_time NULL means the currently effective price.
SELECT u.usage_date, u.cloud, u.sku_name, u.usage_type, u.usage_unit,
       CASE WHEN u.usage_metadata.endpoint_name IS NULL THEN u.usage_metadata.endpoint_name ELSE concat(substr(u.usage_metadata.endpoint_name, 1, 2), '****') END AS endpoint_name,
       u.usage_metadata.endpoint_id   AS endpoint_id,
       lp.currency_code,
       SUM(u.usage_quantity)                AS net_usage_quantity,
       SUM(u.usage_quantity * lp.list_rate) AS net_list_cost,
       -- status: est_usd_list/day band per endpoint (field heuristic; :warn_endpoint_usd_per_day / :crit_endpoint_usd_per_day).
       CASE
         WHEN SUM(u.usage_quantity * lp.list_rate) IS NULL THEN 'NOT_ASSESSED'
         WHEN SUM(u.usage_quantity * lp.list_rate) >= :crit_endpoint_usd_per_day THEN 'CRITICAL'
         WHEN SUM(u.usage_quantity * lp.list_rate) >= :warn_endpoint_usd_per_day THEN 'WARN'
         ELSE 'OK'
       END AS status
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
ORDER BY net_list_cost DESC NULLS LAST
