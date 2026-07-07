# Storage & Optimization

What Predictive Optimization is doing to your Delta tables and what it costs. Clustering / compaction / VACUUM history, table inventory, time-travel retention and Iceberg / UniForm metadata.

📖 **Full interactive docs → [every query, explained](https://learn.crosshire.ch/learn/tech/databricks/audit#d-storage)** — why it matters, what it does, how to read every output column, a sample of the result, and the caveats.

| # | Query | What it does |
|--:|---|---|
| 01 | [`iceberg_uniform_metadata`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-iceberg_uniform_metadata) | For a single target table, returns its full extended metadata rows so the "Delta Uniform Iceberg" section can be read to detect whether the table is UniForm / managed-Iceberg enabled. |
| 02 | [`po_clustering_activity`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-po_clustering_activity) | Per managed Unity Catalog table, a 30-day summary of how many liquid/automatic CLUSTERING operations ran, the files and bytes they compacted (removed vs. clustered), and the estimated DBUs that clustering consumed. |
| 03 | [`po_clustering_column_churn`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-po_clustering_column_churn) | Per managed table (and per distinct old-to-new/reason signature), the auto-clustering column-selection decisions over the last 30 days — whether the keys changed, the old to new column sets, the stated reason, when it last happened, and how many times. |
| 04 | [`po_data_skipping_backfill`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-po_data_skipping_backfill) | One row per managed table and distinct data-skipping column-change set, showing which stat columns Predictive Optimization added, removed, or newly indexed for pruning, plus the bytes and files it scanned to do so, over the trailing 30 days. |
| 05 | [`po_maintenance_cost_by_table`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-po_maintenance_cost_by_table) | One row per table x maintenance-type x outcome over the last 30 days, giving the operation count, summed estimated maintenance DBUs, and first/last op times. |
| 06 | [`po_vacuum_reclaimed_bytes`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-po_vacuum_reclaimed_bytes) | One row per managed table showing how many successful VACUUM operations ran in the last 30 days and how many files, bytes, and estimated DBUs they reclaimed. |
| 07 | [`storage_breakdown_analyze`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-storage_breakdown_analyze) | A single row of one Delta table's true on-disk footprint, split into active data, time-travel history, and reclaimable (vacuumable) bytes and file counts. |
| 08 | [`table_inventory_type`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-table_inventory_type) | A catalog/schema-level census of every table and view visible to your grants, counted by managed/external/view type and by data source format. |
| 09 | [`table_props_time_travel_config`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-table_props_time_travel_config) | For one managed Delta table, the seven Delta properties that govern time-travel retention, auto-optimize, data-skipping indexing, and deletion vectors, each with its effective value or default. |

<sub>★ = first-audit pick. This is a one-line index — the full write-up (output columns, sample rows, caveats) lives in the [interactive docs](https://learn.crosshire.ch/learn/tech/databricks/audit). The `.sql` files in this folder are the source of truth.</sub>
