-- query_id: storage_breakdown_analyze
-- source: ANALYZE TABLE <catalog>.<schema>.<table> COMPUTE STORAGE METRICS (NOT a system table)
-- feeds: storage breakdown (active / time-travel / vacuumable / total); time-travel bloat (size side); PO coverage gap (vacuumable_bytes to dollarize unreclaimed storage)
-- confidence: confirmed (8 result columns + DBR 18.0+ gate verbatim-verified)
-- caveats: GA but DBR 18.0+ only. Computed at run time, NOT stored in UC, NOT returned by DESCRIBE EXTENDED — no history/trend; the engine must run per-table and persist itself (Deep tier only). No fail-safe and no clone bytes exist. Degrade to "not assessed — storage size not in system tables; requires ANALYZE / DBR 18.0+" when not collected.
/* databricks_audit:storage_breakdown_analyze */
-- On-demand, per-table; NOT a system table and NOT persisted to UC. Engine runs this per target
-- table (Deep tier) on a DBR 18.0+ warehouse, then reads the single-row result.
ANALYZE TABLE main.sales.orders COMPUTE STORAGE METRICS;
-- Result columns to capture: total_bytes, num_total_files, active_bytes, num_active_files,
--   vacuumable_bytes, num_vacuumable_files, time_travel_bytes, num_time_travel_files
