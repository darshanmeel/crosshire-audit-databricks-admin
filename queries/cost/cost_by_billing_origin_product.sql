-- query_id: cost_by_billing_origin_product
-- source: system.billing.usage
-- feeds: cost-by-product-line (where the money goes: JOBS / SQL / DLT / MODEL_SERVING / ...) on the Pricing & Allocation tab; product-mix Pareto
-- confidence: confirmed
-- caveats: net_usage_quantity SUMs usage_quantity across ALL record_types so billing corrections (ORIGINAL/RETRACTION/RESTATEMENT) already net out — never re-net downstream and never filter to record_type='ORIGINAL' for a net rollup. usage_unit is carried so the engine isolates DBU rows; non-DBU families (STORAGE_SPACE bytes, hours, TOKEN) must be reported on their own scale, never summed into DBUs. billing_origin_product is the product line; it is populated for billed usage but a blank/NULL value is "unattributed product", not zero. No dollars here — usage_quantity is DBUs/units.
/* databricks_audit:cost_by_billing_origin_product */
SELECT billing_origin_product, usage_unit, cloud,
       SUM(usage_quantity) AS net_usage_quantity,
       COUNT(*)            AS record_count
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY billing_origin_product, usage_unit, cloud
