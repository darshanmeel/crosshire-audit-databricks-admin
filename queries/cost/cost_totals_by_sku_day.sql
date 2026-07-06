-- query_id: cost_totals_by_sku_day
-- source: system.billing.usage
-- feeds: cost totals; per-WORKSPACE cost split (dev/uat/prod); per-workspace product & serverless mix; credit/usage anomalies (time series); % restated (record_type); GenAI/token spend (usage_type slices); DEFAULT_STORAGE/DSU storage cost (billing_origin_product slice)
-- confidence: confirmed
-- caveats: Net corrections by SUMming usage_quantity across ALL record_types — never filter to ORIGINAL only. usage_quantity is DBU/units, not dollars. usage_date is the recommended date-partition column. workspace_id is NULL for account-level SKUs (some MODEL_SERVING/account services) — keep those NULL rows (they roll up as "account-level, not workspace-attributable"). Existing SKU/product totals are unaffected: consumers sum across the finer workspace grain. Workspace NAMES aren't in billing.usage — resolve workspace_id -> name from the account console/API (or hand me a mapping).
/* databricks_audit:cost_totals_by_sku_day */
SELECT usage_date, cloud, workspace_id, sku_name, billing_origin_product, usage_type, usage_unit,
       product_features.is_serverless AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity,
       SUM(CASE WHEN record_type = 'ORIGINAL'    THEN usage_quantity ELSE 0 END) AS original_usage_quantity,
       SUM(CASE WHEN record_type = 'RETRACTION'  THEN usage_quantity ELSE 0 END) AS retraction_usage_quantity,
       SUM(CASE WHEN record_type = 'RESTATEMENT' THEN usage_quantity ELSE 0 END) AS restatement_usage_quantity,
       COUNT(*) AS record_count
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, workspace_id, sku_name, billing_origin_product, usage_type, usage_unit,
         product_features.is_serverless
