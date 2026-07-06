-- query_id: cost_usage_policy_coverage
-- source: system.billing.usage
-- feeds: usage-policy coverage (% serverless spend with no usage_policy_id); chargeback hygiene for serverless; per-WORKSPACE + per-product triage of uncovered serverless (INTERACTIVE = attach a usage POLICY; SQL = TAG the warehouse); policy-uncovered vs tag-uncovered reconciliation
-- confidence: confirmed
-- caveats: usage_policy_id is current; budget_policy_id is DEPRECATED ("Use usage_policy_id instead") and kept only as a fallback for older rows. Policy IDs populate only for serverless usage — compute coverage % over serverless spend only (is_serverless = true). No system table lists policy definitions (name/owner) — that is Budget Policy API only. tag_coverage (custom_tags present?) is tracked SEPARATELY from policy_coverage on purpose: a warehouse can be TAGGED yet still 'none' on policy, so the policy-gap finding must NOT call tagged-SQL "uncovered" — split the fix by product (notebook -> policy, warehouse -> tag). workspace_id lets the gap be closed workspace by workspace.
/* databricks_audit:cost_usage_policy_coverage */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       product_features.is_serverless AS is_serverless,
       CASE WHEN usage_metadata.usage_policy_id  IS NOT NULL THEN 'usage_policy'
            WHEN usage_metadata.budget_policy_id IS NOT NULL THEN 'budget_policy_legacy'
            ELSE 'none' END AS policy_coverage,
       CASE WHEN cardinality(map_keys(custom_tags)) > 0 THEN 'tagged' ELSE 'untagged' END AS tag_coverage,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, workspace_id, billing_origin_product, product_features.is_serverless,
         CASE WHEN usage_metadata.usage_policy_id  IS NOT NULL THEN 'usage_policy'
              WHEN usage_metadata.budget_policy_id IS NOT NULL THEN 'budget_policy_legacy'
              ELSE 'none' END,
         CASE WHEN cardinality(map_keys(custom_tags)) > 0 THEN 'tagged' ELSE 'untagged' END
