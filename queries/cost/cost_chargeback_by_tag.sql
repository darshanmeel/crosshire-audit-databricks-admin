-- query_id: cost_chargeback_by_tag
-- source: system.billing.usage
-- feeds: chargeback/tagging (custom_tags); % untagged DBU spend; per-tag rollups / tag drift; per-WORKSPACE + per-product tag rollup; chargeback-USABLE coverage (a key with >1 distinct value, derived downstream from tag_key/tag_value)
-- confidence: confirmed
-- caveats: explode OUTER so rows with empty/NULL custom_tags still appear (drives the "% untagged" denominator) — pair with cost_totals_by_sku_day for the total. custom_tags keys vary per customer (dynamic map) — do not hardcode key names. Tags originate from compute-resource tags AND serverless usage policies. NOTE for this account: one umbrella key can cover ~100% of DBUs yet give NO team-level chargeback (single cost center) — count distinct tag_values per tag_key to expose that, don't report a bare "100% tagged". workspace_id lets chargeback be cut per workspace.
/* databricks_audit:cost_chargeback_by_tag */
SELECT usage_date, cloud, workspace_id, billing_origin_product, tag_key, tag_value,
       SUM(usage_quantity) AS net_usage_quantity,
       COUNT(*) AS record_count
FROM system.billing.usage
     LATERAL VIEW OUTER explode(custom_tags) t AS tag_key, tag_value
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, workspace_id, billing_origin_product, tag_key, tag_value
