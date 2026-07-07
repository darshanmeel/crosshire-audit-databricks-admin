-- query_id: cost_dbsql_allocation_gap
-- title: DBSQL raw vs attributed DBU allocation gap
-- domain: cost   tier: deep
-- reads: system.billing.usage, system.billing.attributed_usage
-- requires: SELECT on system.billing; GA (system.billing.usage and system.billing.attributed_usage are generally available)
-- params: :period_days (default 30) rolling window in days
-- confidence: needs_confirmation
-- confidence_note: system.billing.attributed_usage's quantity column is active_usage_quantity, not usage_quantity; confirm that column and the billing_origin_product = 'SQL' literal for DBSQL scope on your account before trusting the gap.
-- read_this: One row = either the raw or the attributed DBSQL DBU total for a day + cloud, labeled by source_kind. Difference the two source_kind rows for the same day/cloud yourself: raw minus attributed is the DBU volume Databricks' fair-split allocation could not attribute back to a consuming entity - a large, persistent gap points at cross-subsidized shared SQL-warehouse pools.
-- healthy: n/a - the gap is a difference you compute between this query's 'raw' and 'attributed' rows for the same key, not a single-row band; a small, stable gap is the healthy case (field heuristic).
-- investigate_if: a growing or large raw-minus-attributed gap for the same day/cloud - field heuristic; this needs the two rows differenced yourself, so no per-row status is computed here (see caveats).
-- actions: 1) confirm which SQL warehouses are shared/multi-tenant vs single-team, since fair-split allocation struggles most on shared pools (free); 2) split a heavily shared warehouse into per-team warehouses, or enable/verify usage-policy tagging on it so attribution has more to work with (config); 3) if the gap is small and structural, accept it and document the residual as an allocation cost of shared infrastructure (spend, in the sense of accepted overhead).
-- next: cost_usage_policy_coverage (uncovered serverless DBSQL usage is one likely driver of the gap), cost_chargeback_by_identity (for an identity-level cut of the same SQL usage)
-- caveats: attributed_usage carries Databricks' fair-split allocation of shared-pool DBUs back to the consuming entity, but its coverage is DBSQL (SQL warehouses) only - it does not cover jobs/DLT/all-purpose. So the gap (raw DBSQL DBUs minus attributed DBSQL DBUs) is meaningful only when both sides are scoped to DBSQL, which is why both branches here filter to billing_origin_product = 'SQL'. This deliberately does not join the two tables row-to-row - the two source_kind rows are emitted separately via UNION ALL precisely so you difference them yourself for the same day/cloud, which is also why no per-row status/band is computed in this query: a CRITICAL/WARN verdict belongs on the differenced gap, not on either row alone. In particular this does not join run_as = executed_by: those are different identities (run_as is the workload's principal, executed_by/attributed identity is the query author), and equating them would be a real bug. Net DBUs sum usage_quantity (raw) / active_usage_quantity (attributed) across all record_types (corrections already netted). usage_unit is filtered to DBU. If system.billing.attributed_usage or its active_usage_quantity column is absent on your account, this branch errors and the source degrades to not_assessed honestly rather than guessing.
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
ORDER BY usage_date DESC, cloud, billing_origin_product, source_kind
