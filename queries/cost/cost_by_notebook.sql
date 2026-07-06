-- query_id: cost_by_notebook
-- source: system.billing.usage (usage_metadata.notebook_id)
-- feeds: per-NOTEBOOK interactive/ad-hoc DBU cost -> which notebooks (human ad-hoc work) cost the most; puts a $ on the "~3% is ad-hoc" workload split; per-workspace ad-hoc cost
-- confidence: needs_confirmation (usage_metadata.notebook_id is documented but populates only for notebook-attached all-purpose/interactive usage — confirm it's non-empty in this account before promising a per-notebook view)
-- caveats: usage_metadata.notebook_id populates for notebook-attached interactive/all-purpose usage; NULL for jobs/serverless-editor/SQL. No notebook NAME in billing (usage_metadata.notebook_path MAY exist — verify per account). Ad-hoc notebook cost is expected to be small here (the workload split shows ~3% ad-hoc) — this confirms/quantifies that, and flags any single runaway notebook. usage_quantity is DBU, not dollars.
/* databricks_audit:cost_by_notebook */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.notebook_id     AS notebook_id,
       product_features.is_serverless AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_unit = 'DBU'
  AND usage_metadata.notebook_id IS NOT NULL
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         usage_metadata.notebook_id, product_features.is_serverless
