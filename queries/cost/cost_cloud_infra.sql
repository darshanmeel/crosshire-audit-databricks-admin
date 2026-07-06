-- query_id: cost_cloud_infra
-- source: system.billing.cloud_infra_cost
-- feeds: cloud infrastructure / egress cost that sits OUTSIDE DBU pricing (instance + network), on the Pricing & Allocation tab; surfaces the 10-25% of spend DBUs miss
-- confidence: needs_confirmation
-- caveats: cloud_infra_cost is the cloud provider's own infra charge (instance hours, network/egress), NOT DBUs — it is a REAL billed dollar in the row's currency, separate from the usage table. It is largely AWS-only and is empty on many accounts (network policy / provider export not enabled) — an empty result must render "not assessed", never $0. We aggregate by the table's OWN dimensions (usage_date / cloud / currency_code) and deliberately do NOT LEFT JOIN compute.warehouses / clusters here: those are change-history tables and joining them fans out the rows and double-counts SUM(cost) (the must-fix dedupe bug). Attribution to a warehouse/cluster, if needed, must dedupe the dimension to its latest row per id FIRST — done in a separate step, not in this rollup.
-- NEEDS WORKSPACE CONFIRMATION: the monetary column is assumed to be `cost` (DOUBLE) and the date column `usage_date` per the roadmap; the exact column names on system.billing.cloud_infra_cost are not verified on this workspace. If `cost` is absent the query errors and the source degrades to not_assessed honestly (never a fabricated 0). currency_code is assumed present; if absent the rollup still binds on usage_date+cloud.
/* databricks_audit:cost_cloud_infra */
SELECT usage_date, cloud, currency_code,
       SUM(cost)  AS net_infra_cost,
       COUNT(*)   AS record_count
FROM system.billing.cloud_infra_cost
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, currency_code
