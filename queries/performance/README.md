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

## Queries

All queries are `SELECT`-only reads of `system.query.history`. Depth is labeled by what each does: **detail** (per-statement rows), **aggregate** (grouped rollup), or **estimate-input** (feeds downstream cost allocation).

### Heaviest statements & cost inputs
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `query_costly_statements` | *(detail)* Top ~1000 finished, non-cached statements ranked by `execution_duration_ms`, with per-statement pruning/shuffle/spill/scan counters and de-valued `statement_text`. | The single best "what to tune first" list — ranking by execution time ≈ ranking by DBU cost, and the attached signals tell you the fix (pruning vs. spill vs. shuffle). |
| `query_per_query_estimate_lane` | *(estimate-input)* Per-statement duration/task/read_bytes drivers for finished, non-cached, warehouse (non-serverless) statements, bucketed by hour. | Raw input for downstream per-query dollar estimation; lets you approximate cost per statement even though Databricks exposes none. Bound the window — output can be large. |
| `audit_self_cost` | *(aggregate)* Count + runtime of the audit's **own** queries (matched via the `databricks_audit` marker), by workspace and statement_type. | Measures what running this audit itself costs the workspace — full transparency, and the inverse of self-exclusion. |

### Tuning signals
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `query_pruning_effectiveness` | *(aggregate)* Daily `pruned_files` vs `read_files` (plus partitions/bytes/rows), by warehouse/user/statement_type. | Low pruning = full scans; points at missing partitioning, clustering, or Z-order / liquid clustering opportunities. |
| `query_local_spillage` | *(aggregate)* Daily count and sum/max of `spilled_local_bytes` for spilling statements, with shuffle context. | Local spill = memory pressure; identifies statements that need a bigger warehouse or a rewrite. (Remote spill is not measurable.) |
| `query_shuffle_write_amplification` | *(aggregate)* Daily `shuffle_read_bytes` and `written_bytes/rows/files`, by warehouse/user/statement_type. | High shuffle flags bad joins; high `written_files` per row flags the small-files-on-write problem (later OPTIMIZE / compaction target). |
| `query_cache_coldstart` | *(aggregate)* Daily result-cache hits, average/low `read_io_cache_percent`, and summed compute-wait + compilation time, per warehouse. | Separates the two cache signals and quantifies cold-start vs. compile-bound latency — informs warehouse auto-stop / warm-pool tuning. |
| `query_queuing_waits` | *(aggregate)* Daily counts and summed durations for "queued at capacity" vs "waiting for compute", per warehouse. | Distinguishes under-provisioned warehouses (capacity queuing) from cold-start latency — different fixes (scale-out vs. keep warm). |

### Reliability, mix & provenance
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `query_failed_queries_daily` | *(aggregate)* Daily FAILED/CANCELED counts, durations, and a de-valued `error_message` sample, by warehouse/user/statement_type. | Surfaces failing workloads and their error shapes; wasted compute and reliability hotspots. (`error_message` is blank under CMK.) |
| `query_workload_mix_hours` | *(aggregate)* Day × hour-of-day × compute × statement_type × user histogram with counts, durations, bytes, produced rows. | Shows when and what the workload is — peak-hour concentration informs scheduling, autoscaling, and warehouse sizing. |
| `query_provenance_by_source` | *(aggregate)* Attributes statements to a source (job / dashboard / notebook / alert / genie / sql_editor) and identity type (user vs. service principal), with counts and durations. | Reveals whether spend is scheduled jobs vs. ad-hoc exploration and who drives it. **Confidence: needs confirmation** — nested `query_source` dotted-path access and single-winner CASE precedence are unverified; simultaneous subfield population means CASE is a heuristic. |

## Notes

- **Date window.** Most queries hard-code `start_time >= current_date() - INTERVAL 30 DAYS AND start_time < current_date()`, i.e. the **last 30 complete days, excluding today** (avoids a partial current day and ingest latency). Two queries are parameterized with `:period_days` (`query_costly_statements`, `query_per_query_estimate_lane`, `audit_self_cost` — the latter includes today on purpose to capture its own in-flight run).
- **Cost is a proxy, not a fact.** There is **no per-query DBU or dollar column**. `execution_duration_ms` is used as the cost proxy; true dollars are only estimated downstream against `system.billing.usage` (see billing domain).
- **Masking.** `executed_by` is always partial-masked in output (emails → `xx****@****`, service-principal GUIDs kept as opaque handles). `statement_text` and `error_message` are de-valued at source: emails replaced with `<email>` and every single-quoted string literal replaced with `?`, preserving query **shape** while removing literal data values. A `--share` full-redact build truncates `statement_text`/`error_message` entirely.
- **Compute coverage gotcha.** Classic / all-purpose (interactive) cluster statements are **not** in `system.query.history`. Any "0 spills / 0 shuffle" result may just mean the work ran on classic compute, not that there's no problem. Serverless rows have `warehouse_id = NULL`.
- **NULL-vs-0 ambiguity.** For non-scan statements, the NULL-vs-0 behavior of counters like `read_io_cache_percent`, `pruned_files`, and `waiting_for_compute_duration_ms` on warm warehouses is undocumented; treat NULL and 0 as equivalent "no signal / no wait" and note WHERE guards exclude non-scan/non-write rows where relevant.
- **Regional.** History is per-region; when combining with billing, attribute only within-region.
- **Downstream rename.** `spilled_local_bytes` is renamed to `disk_bytes_spilled` by the collector/loader downstream — expect that alias outside the raw SQL.
