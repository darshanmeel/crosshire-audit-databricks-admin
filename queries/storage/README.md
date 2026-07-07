# Storage & Optimization

> 📖 **Guided HTML tour:** [`docs/index.html`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. *(Phase 1 covers the top 10 across cost, jobs, compute, performance and governance; this domain's queries are documented in a later phase.)*

This domain answers "what is Databricks doing to maintain my Delta tables, what is it costing, and where is storage going to waste?" It pairs the **Predictive Optimization (PO) operations history** — the account-wide audit log of automatic OPTIMIZE / clustering / VACUUM / stats-backfill runs and their estimated DBU cost — with a **table inventory** (managed vs. external vs. view) and a set of **per-table probes** (`ANALYZE … COMPUTE STORAGE METRICS`, `DESCRIBE EXTENDED`) that fill the gaps system tables don't cover: physical size breakdown, time-travel retention config, and Iceberg/UniForm metadata.

## System tables used

### system.storage.predictive_optimization_operations_history

The audit log of every maintenance operation that Predictive Optimization (and automatic/liquid clustering) performed on your Unity Catalog managed tables — OPTIMIZE/compaction, liquid CLUSTERING, VACUUM, and data-skipping/clustering **column-selection** decisions — each stamped with an **estimated** DBU cost.

- **Grain:** one row per maintenance **operation** on a table (identified by `table_id`), of a given `operation_type`, at a given `start_time`/`end_time`. The queries here aggregate that grain up to per-table / per-op-type / per-status.
- **Key columns:**
  - `account_id`, `workspace_id`, `metastore_name`, `catalog_name`, `schema_name`, `table_name`, `table_id` — where the table lives; `table_id` is the stable identity (name can be reused/renamed).
  - `operation_type` — the maintenance kind: `CLUSTERING`, `VACUUM`, `AUTO_CLUSTERING_COLUMN_SELECTION`, `DATA_SKIPPING_COLUMN_SELECTION` (and OPTIMIZE/compaction). Each type populates a **different** set of keys in `operation_metrics`.
  - `operation_status` — outcome; observed enum is `SUCCESSFUL` or `'FAILED: INTERNAL_ERROR'` (note the embedded colon). Drives per-table success-rate / failing-table findings.
  - `operation_metrics` — `map<string,string>` of per-op counters; **must be cast** for numeric use. Documented keys by type: CLUSTERING → `number_of_removed_files`, `number_of_clustered_files`, `amount_of_data_removed_bytes`, `amount_of_clustered_data_bytes`; VACUUM → `number_of_deleted_files`, `amount_of_data_deleted_bytes`; AUTO_CLUSTERING_COLUMN_SELECTION → `has_column_selection_changed`, `old_clustering_columns`, `new_clustering_columns`, `additional_reason` (all categorical strings; `old_clustering_columns` = `'None'` when previously unpartitioned); DATA_SKIPPING_COLUMN_SELECTION → `added_/removed_/new_data_skipping_columns` (string lists), `amount_of_scanned_bytes`, `number_of_scanned_files` (+ an `old_data_skipping_columns` key not selected here).
  - `usage_quantity` + `usage_unit` — the **ESTIMATED_DBU** consumed by the op (SUM only; it is an estimate, not the billed line). Value may lag the operation row up to ~24h as billing populates, so the most recent day is provisional.
  - `start_time`, `end_time` — op window; used for the 30-day filter and for MIN/MAX first/last-op times.
- **Availability:** **Public Preview.** Requires **Unity Catalog** and that **Predictive Optimization** is enabled for the metastore/tables (Enterprise-tier feature); only **managed** UC tables are PO-eligible, so external tables never appear. **Regional** (not in every cloud region) with ~**180-day retention**. Reader needs `SELECT` on `system.storage`. If PO is off or nothing ran in-window, the query returns **zero rows** (valid, not an error); if the schema isn't enabled you may get `TABLE_OR_VIEW_NOT_FOUND`.

### system.information_schema.tables

The Unity Catalog catalog-of-tables view — the inventory of every table/view the querying principal can see.

- **Grain:** one row per table or view in Unity Catalog. The query aggregates to a count per catalog/schema/type/format.
- **Key columns:**
  - `table_type` — `MANAGED`, `EXTERNAL`, or `VIEW` (doc-confirmed). EXTERNAL = not PO-eligible, so this bounds the PO coverage gap.
  - `table_catalog`, `table_schema` — location (plausible `information_schema` names; **unverified** in this repo's doc audit).
  - `data_source_format` — e.g. `DELTA` / `ICEBERG`, used to flag Iceberg/UniForm candidates (**unverified** name/presence).
  - `COUNT(*)` as `table_count` — inventory size per group.
- **Availability:** Part of standard SQL `information_schema` under **Unity Catalog** (per-catalog view exposed under `system.information_schema` for the metastore). **Privilege-aware** — a principal sees only tables it has privileges on, so counts reflect the collector's grants, not necessarily the whole metastore. Carries **no size columns** (size requires the `ANALYZE` probe below). Requires UC; empty/partial if the principal lacks broad grants.

> Note: `system.storage.table_metrics_history` is a primary table of this domain but is **not referenced** by any query in this folder — physical/size metrics here come from the on-demand `ANALYZE` probe instead (see Notes).

## Non-system-table probes (per-table, run on a warehouse)

These are **not** system tables — they are on-demand statements the collection engine runs per target table because the data does not exist in any system table.

### ANALYZE TABLE … COMPUTE STORAGE METRICS (`storage_breakdown_analyze`)
Returns a single row of physical size: `total_bytes`, `num_total_files`, `active_bytes`, `num_active_files`, `vacuumable_bytes`, `num_vacuumable_files`, `time_travel_bytes`, `num_time_travel_files`. **GA but DBR 18.0+ only.** Computed at run time, **not** stored in UC and **not** returned by `DESCRIBE EXTENDED` — no history/trend, the engine must run it per-table and persist the result itself.

### DESCRIBE EXTENDED / SHOW TBLPROPERTIES (`table_props_time_travel_config`, `iceberg_uniform_metadata`)
Delta table properties (`delta.logRetentionDuration`, `delta.deletedFileRetentionDuration`, `delta.dataSkippingNumIndexedCols`, `delta.dataSkippingStatsColumns`, `delta.autoOptimize.optimizeWrite`, `delta.autoOptimize.autoCompact`, `delta.enableDeletionVectors`) and the "Delta Uniform Iceberg" metadata section. Retention values are CalendarInterval strings (e.g. `'interval 30 days'`) that must be parsed to days.

---

**Per-query documentation** — what each query does, why it matters, how to read every output column, an illustrative sample of the result, and the caveats — lives in the guided HTML tour: **[read it rendered →](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#d-storage)**. The `.sql` files in this folder are the source of truth.

