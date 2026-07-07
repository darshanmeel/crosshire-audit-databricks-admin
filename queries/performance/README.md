# Query Performance

> 📖 **Guided HTML tour:** [`docs/index.html`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. From this domain: [`query_costly_statements`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-query_costly_statements). *(Phase 1 = top 10; more in phases.)*

This domain answers "which SQL statements are slow, wasteful, or failing — and why?" using Databricks' per-statement execution telemetry. It surfaces the heaviest statements (a stand-in for cost, since Databricks exposes **no** per-query dollar column), plus the specific tuning signals behind them: file pruning, disk spill, shuffle/write amplification, cache/cold-start behavior, queuing waits, failures, workload mix by hour, and query provenance (job vs. dashboard vs. ad-hoc). Every query here reads a single system table — `system.query.history` — so availability and caveats are shared across the whole folder.

## System tables used

### `system.query.history`

**What it is.** A record of completed query/statement executions across the account's compute, with rich per-statement performance and I/O counters. This is the system-table equivalent of the SQL editor's Query History, exposed for SQL analytics rather than one-off UI inspection.

**Grain.** One row per completed statement execution (identified by `statement_id`). Aggregating queries in this folder roll that grain up to day × workspace × warehouse × statement_type × user, etc.; the detail queries (`query_costly_statements`, `query_per_query_estimate_lane`) keep the native one-row-per-statement grain.

**Key columns these queries use:**

- `statement_id` — unique id of the statement execution (join/dedup key; row grain).
- `statement_type` — SELECT / INSERT / MERGE / UPDATE / etc.; used to split workload and to find write-heavy statements.
- `statement_text` — the SQL text. Used to detect the audit's own marker (`ILIKE '%databricks_audit%'`) and, in detail queries, emitted only after emails and single-quoted string literals are stripped at source (shape kept, data values removed).
- `execution_status` — enum `FINISHED` / `FAILED` / `CANCELED`. Filters "successful only" lanes and drives the failed-queries report.
- `error_message` — failure text (de-valued at source). Note: **empty under customer-managed keys (CMK)**.
- `executed_by` — the principal (user email or service-principal GUID). Always partial-masked in output (e.g. `da****@****`; GUIDs kept as opaque handles). `identity_type` is derived from whether it looks like an email.
- `start_time` — statement start timestamp; the sole date-window filter and the basis for `day` / `hour_of_day` / `usage_hour` bucketing.
- `total_duration_ms` — end-to-end wall time (includes waiting).
- `execution_duration_ms` — pure execution time; used as the **cost proxy** (warehouse DBUs are allocated ~ proportionally to it) for ranking and for the per-query estimate lane.
- `total_task_duration_ms` — summed task (CPU) time across the cluster; a parallelism/compute-intensity signal.
- `waiting_for_compute_duration_ms` — time waiting for compute to provision (cold-start / warehouse spin-up).
- `waiting_at_capacity_duration_ms` — time queued because the warehouse was at capacity.
- `compilation_duration_ms` — metadata/optimizer/compile time (planner-bound latency).
- `read_bytes`, `read_files`, `read_partitions`, `read_rows` — scan I/O; `read_partitions` is a **post-pruning** count, not "partitions pruned".
- `pruned_files` — files skipped by data/file pruning; pruning effectiveness = `pruned_files / (pruned_files + read_files)`.
- `produced_rows` — rows returned to the client (distinct from `read_rows`).
- `spilled_local_bytes` — bytes spilled to local disk (memory pressure). **Local spill only** — there is no `spilled_remote_bytes` column in Databricks.
- `shuffle_read_bytes` — shuffle volume; a bad-join / shuffle-heavy signal.
- `written_bytes`, `written_rows`, `written_files` — write output; `written_files` vs `written_rows` flags the small-files / write-amplification problem.
- `from_result_cache` (boolean) — served from the result cache. Distinct from…
- `read_io_cache_percent` — % of scan bytes served from the disk/IO cache (NOT the same signal as `from_result_cache`).
- `compute` (struct) — `compute.type` (e.g. warehouse vs. serverless) and `compute.warehouse_id`. **Serverless rows carry `warehouse_id = NULL`.**
- `query_source` (nested struct) — provenance: `query_source.job_info.job_id`, `.dashboard_id`, `.legacy_dashboard_id`, `.notebook_id`, `.alert_id`, `.genie_space_id`, `.sql_query_id`. Each subfield is NULL when that entity wasn't involved, and **multiple subfields can populate simultaneously** (they are not execution-ordered), so single-winner CASE attribution is a heuristic.
- `workspace_id` — the workspace that ran the statement (every query groups by this).

**Availability.**
- **Unity Catalog required**; you must have `SELECT` on `system.query.history` (system schemas are access-controlled, granted per-metastore by an admin).
- The `query` system schema may need to be **enabled per-metastore** and has been in **Preview** — an unqueryable/undisabled schema yields `TABLE_OR_VIEW_NOT_FOUND`.
- **Regional / per-region:** history is scoped to the region; attribute costs only within-region.
- **Coverage is compute-limited:** captures **SQL warehouses and serverless**; classic / all-purpose (interactive) cluster statements are **NOT** recorded here. So spill, shuffle, and pruning signals for classic-cluster jobs will simply be absent.
- **Empty-if-unused:** a workspace with no matching activity (e.g. no failed queries, no serverless usage) returns zero rows — valid, not an error.
- **CMK degradation:** under customer-managed encryption keys, `error_message` comes back blank.
- Short **ingest latency** — the most recent minutes of an in-flight run may not appear yet.

### `system.billing.usage` (referenced downstream only)

**Not read by any `.sql` file in this folder.** Because `system.query.history` has no per-statement dollar/DBU column, the per-query **estimate lane** (`query_per_query_estimate_lane`) emits only the raw drivers (`execution_duration_ms`, `total_task_duration_ms`, `read_bytes`), and the actual dollar attribution happens **downstream** by weighting hourly warehouse DBUs from `system.billing.usage` and reconciling so per-query estimates sum to metered DBU. See the billing/cost domain README for that table's grain, columns, and availability.

---

**Per-query documentation** — what each query does, why it matters, how to read every output column, an illustrative sample of the result, and the caveats — lives in the guided HTML tour: **[read it rendered →](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#d-performance)**. The `.sql` files in this folder are the source of truth.

