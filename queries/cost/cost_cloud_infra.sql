-- query_id: cost_cloud_infra
-- source: system.billing.usage JOIN system.billing.list_prices
-- feeds: estimated billed cost by cloud, on the Pricing & Allocation tab. NOTE: Databricks does NOT expose a separate cloud-provider infra/egress cost system table in this environment (system.billing.cloud_infra_cost does not exist), so the original non-DBU infra-spend intent is not_assessed; this query reports DBU-derived billed cost from usage x list_prices as the closest real, runnable source.
-- confidence: needs_confirmation
-- caveats: system.billing.cloud_infra_cost does NOT exist in this workspace -- system.billing contains only usage, list_prices, and attributed_usage. Cloud-provider infra/instance/egress cost outside DBUs is NOT available as a system table here and must be treated as not_assessed, never fabricated. As a real substitute this query estimates dollar cost = usage_quantity x list_prices.pricing.default, matched on sku_name+cloud+usage_unit within the price's effective window (price_end_time IS NULL = currently effective). currency_code comes from list_prices (system.billing.usage has no currency column). We aggregate by usage_date / cloud / currency_code and deliberately do NOT join the compute.warehouses / clusters change-history tables here, which would fan out rows and double-count SUM(cost). An empty result must render "not assessed", never $0.
/* databricks_audit:cost_cloud_infra */
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