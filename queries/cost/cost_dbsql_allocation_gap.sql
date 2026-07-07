-- query_id: cost_dbsql_allocation_gap
-- source: system.billing.usage UNION ALL system.billing.attributed_usage
-- feeds: attributed-vs-raw allocation gap for DBSQL (finds cross-subsidized shared SQL-warehouse pools); unattributed DBU % on the Pricing & Allocation tab
-- confidence: needs_confirmation
-- caveats: attributed_usage carries Databricks' FAIR-SPLIT allocation of shared-pool DBUs back to the consuming entity, but its coverage is DBSQL (SQL warehouses) ONLY — it does NOT cover jobs/DLT/all-purpose. So the gap (raw DBSQL DBUs - attributed DBSQL DBUs) is meaningful ONLY when BOTH sides are scoped to DBSQL; comparing raw-all vs attributed reports a fake "gap" for everything attributed_usage simply doesn't track. Both sides are scoped here to billing_origin_product = 'SQL'. We emit two labeled rollups in ONE result set (source_kind = 'raw' | 'attributed') via UNION ALL and let the engine difference them — we deliberately do NOT join the two tables row-to-row, and in particular we do NOT join run_as = executed_by: those are DIFFERENT identities (run_as is the workload's principal; executed_by/attributed identity is the query author), and equating them is the must-fix identity bug. Net DBUs SUM usage_quantity (raw) / active_usage_quantity (attributed) across all record_types (corrections already net). usage_unit filtered to DBU.
-- NEEDS WORKSPACE CONFIRMATION: system.billing.attributed_usage quantity column is active_usage_quantity (NOT usage_quantity, which is the raw system.billing.usage column); `usage_unit`, `usage_date`, `billing_origin_product`, `cloud` mirror system.billing.usage. If a column is absent the query errors and the source degrades to not_assessed honestly. DBSQL scope is taken as billing_origin_product = 'SQL'; confirm the literal product value for SQL warehouses on this account (it surfaces in cost_by_billing_origin_product).
/* databricks_audit:cost_dbsql_allocation_gap */
SELECT 'raw' AS source_kind,
       u.usage_date, u.cloud, u.billing_origin_product, u.usage_unit,
       SUM(u.usage_quantity) AS net_usage_quantity
FROM system.billing.usage u
WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
  AND u.usage_date < current_date()
  AND upper(u.usage_unit) = 'DBU'
  AND u.billing_origin_product = 'SQL'   -- DBSQL scope ONLY (attributed_usage doesn't cover jobs/DLT)
GROUP BY u.usage_date, u.cloud, u.billing_origin_product, u.usage_unit
UNION ALL
SELECT 'attributed' AS source_kind,
       a.usage_date, a.cloud, a.billing_origin_product, a.usage_unit,
       SUM(a.active_usage_quantity) AS net_usage_quantity
FROM system.billing.attributed_usage a
WHERE a.usage_date >= dateadd(day, -:period_days, current_date())
  AND a.usage_date < current_date()
  AND upper(a.usage_unit) = 'DBU'
  AND a.billing_origin_product = 'SQL'   -- same DBSQL scope on both sides
GROUP BY a.usage_date, a.cloud, a.billing_origin_product, a.usage_unit
