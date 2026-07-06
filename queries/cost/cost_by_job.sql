-- query_id: cost_by_job
-- source: system.billing.usage (usage_metadata.job_id)
-- feeds: per-JOB DBU cost -> which jobs cost the most; DOLLARIZES the jobs-on-all-purpose premium (the 17 jobs) and per-job failed-run waste; per-workspace job cost
-- confidence: confirmed
-- caveats: usage_metadata.job_id populates for jobs-compute (classic AND serverless); NULL for interactive / SQL-editor lines. NAMES/owner aren't here — join job_id -> system.lakeflow.jobs (SCD2, take latest by change_time) downstream for name + run_as. is_serverless separates jobs-serverless from classic jobs compute (the placement-premium signal). usage_quantity is DBU, not dollars.
/* databricks_audit:cost_by_job */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       usage_metadata.job_id          AS job_id,
       product_features.is_serverless AS is_serverless,
       SUM(usage_quantity) AS net_usage_quantity,
       COUNT(DISTINCT usage_metadata.job_run_id) AS distinct_runs
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
  AND usage_unit = 'DBU'
  AND usage_metadata.job_id IS NOT NULL
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         usage_metadata.job_id, product_features.is_serverless
