-- query_id: cost_cloud_infra
-- title: Estimated billed cost by cloud (DBU-derived)
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.list_prices are generally available)
-- params: :period_days (default 30) rolling window in days
-- confidence: needs_confirmation
-- confidence_note: system.billing.cloud_infra_cost does not exist in this workspace; this query substitutes a DBU-derived list-price estimate, so the dollar figures here are an estimate, not a reconciled cloud bill.
-- read_this: One row = a day + cloud + currency's estimated billed cost. The column that matters is net_billed_cost, an estimate = usage_quantity x list_prices.pricing.default matched to the price row that was active on that usage row - not a substitute for your cloud provider's own cost export.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: cost_totals_by_sku_day (for the same window broken out by SKU/workspace instead of cloud/currency), cost_networking_egress (for the DBU-billed egress slice specifically)
-- caveats: system.billing.cloud_infra_cost does not exist in this workspace - system.billing contains only usage, list_prices, and attributed_usage. Cloud-provider infra/instance/egress cost outside DBUs is not available as a system table here and must be treated as not_assessed, never fabricated. As a real substitute, this query estimates dollar cost as usage_quantity x list_prices.pricing.default, matched on sku_name + cloud + usage_unit within the price's effective window (price_end_time IS NULL = currently effective). currency_code comes from list_prices because system.billing.usage has no currency column. This aggregates by usage_date / cloud / currency_code and deliberately does not join the compute.warehouses / clusters change-history tables, which would fan out rows and double-count the SUM. An empty result means "not assessed," never $0.
SELECT u.usage_date, u.cloud, lp.currency_code,
       SUM(u.usage_quantity * lp.pricing.default) AS net_billed_cost,
       COUNT(*)                                   AS record_count
FROM system.billing.usage u
LEFT JOIN system.billing.list_prices lp
  ON u.sku_name = lp.sku_name
 AND u.cloud = lp.cloud
 AND u.usage_unit = lp.usage_unit
 AND u.usage_end_time >= lp.price_start_time
 AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
GROUP BY u.usage_date, u.cloud, lp.currency_code
ORDER BY u.usage_date DESC, u.cloud, lp.currency_code
