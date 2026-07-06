# Jobs & Pipelines (Lakeflow)

> 📖 **Guided HTML tour:** [`docs/index.html`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. From this domain: [`lakeflow_jobs_on_all_purpose`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-lakeflow_jobs_on_all_purpose), [`lakeflow_failed_jobs_wasted_dbus`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-lakeflow_failed_jobs_wasted_dbus). *(Phase 1 = top 10; more in phases.)*

This domain audits the **reliability, ownership, timeout hygiene, and cost** of Databricks Jobs (workflows) and Lakeflow Declarative Pipelines (formerly Delta Live Tables). It answers questions an admin actually gets asked: *which jobs fail and burn DBUs, which jobs run on the wrong (all-purpose) compute, which have no timeout or no owner, how much does each DLT pipeline cost, and where is time lost to queueing, cold starts, and retries.* Everything is derived from the `system.lakeflow.*` schema (job/pipeline metadata + run timelines), joined to `system.billing.usage` for dollars and, in one case, `system.compute.clusters` for the compute type.

---

## System tables used

### `system.lakeflow.jobs`
The catalog of Jobs (workflow definitions), one **SCD2 change-history** table.
- **Grain:** one row per *version* of a job — i.e. one row per `(workspace_id, job_id)` per configuration change. You must dedupe to the latest row with `QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, job_id ORDER BY change_time DESC) = 1` or job counts inflate.
- **Key columns used:** `workspace_id`, `job_id` (unique only *within* a workspace), `name`, `change_time` (SCD2 ordering key), `delete_time` (non-NULL = user-deleted; filter `IS NULL` for active jobs), `timeout_seconds` (job-level timeout), `paused`, `create_time`, `creator_user_name` / `run_as_user_name` (identity), `run_as`, `creator_id`, `health_rules` (array/struct of configured health rules).
- **Availability:** GA, Unity Catalog required. Needs `SELECT` on the `system` catalog (an admin must `GRANT` access to the `system.lakeflow` schema). Several columns are **late-populated**: `creator_user_name`, `run_as_user_name`, `health_rules` not populated before ~late-Nov-2025; `timeout_seconds` not before ~early-Dec-2025 — so on short-history accounts these are NULL for every job and must degrade to "not assessed," never read as a finding. FedRAMP/redacted workspaces emit `__REDACTED__` for identities.

### `system.lakeflow.job_tasks`
The per-task definition within each job, also **SCD2**.
- **Grain:** one row per *version* of a task — `(workspace_id, job_id, task_key)` per change. `task_key` is unique only within a job. Dedupe to latest by `change_time`.
- **Key columns used:** `workspace_id`, `job_id`, `task_key`, `timeout_seconds` (task-level timeout), `change_time`, `delete_time`.
- **Availability:** GA, UC required, `SELECT` on system needed. `timeout_seconds` late-populated (~early-Dec-2025) → NULL degrades to "not assessed."

### `system.lakeflow.job_run_timeline`
The run-level execution log — the reliability workhorse of this domain.
- **Grain:** one row per run *state slice*. A run that exceeds one hour is **sliced hourly**, so `COUNT(*)` ≠ `COUNT(DISTINCT run_id)`. The **end row** (final slice) is the only one carrying `result_state`, `termination_code`, and the final durations — every reliability query filters `result_state IS NOT NULL` to isolate it. Retries reuse the same `run_id`, appearing as extra end rows.
- **Key columns used:** `workspace_id`, `job_id`, `run_id`, `run_type` (`JOB_RUN` / `SUBMIT_RUN` / `WORKFLOW_RUN`), `trigger_type` (incl. `RETRY_ON_FAILURE`), `result_state` (`SUCCEEDED` / `FAILED` / `ERROR` / `TIMED_OUT` / `SKIPPED` / `CANCELLED` / `BLOCKED`), `termination_code` (root-cause code, e.g. `WORKSPACE_RUN_LIMIT_EXCEEDED`, `MAX_JOB_QUEUE_SIZE_EXCEEDED`, `CLUSTER_ERROR`, `STORAGE_ACCESS_ERROR`), `termination_type` (coarser class — value enum unverified), `period_start_time` / `period_end_time` (equal when a run never began executing), and phase durations `queue_duration_seconds`, `setup_duration_seconds`, `execution_duration_seconds`, `cleanup_duration_seconds`, `run_duration_seconds`.
- **Availability:** GA, UC required. `termination_code` not populated before ~Aug-2024; `queue_duration_seconds`, the phase `*_duration_seconds`, and `termination_type` not before ~late-Nov/early-Dec-2025. `queue_duration_seconds` exists **only here**, not on `job_task_run_timeline`. Empty if the account runs no jobs.

### `system.lakeflow.job_task_run_timeline`
Task-level execution log, one grain finer than `job_run_timeline`.
- **Grain:** one row per task *state slice* per run; hourly-sliced like the run timeline. End row (`result_state IS NOT NULL`) carries final task state and `execution_duration_seconds`. Joins up to the run via `job_run_id = job_run_timeline.run_id` (+ `workspace_id`).
- **Key columns used:** `workspace_id`, `job_id`, `run_id` / `job_run_id`, `task_key`, `result_state`, `execution_duration_seconds`, `compute_ids` (array of cluster ids the task ran on), `period_start_time` / `period_end_time`.
- **Availability:** GA, UC required. `execution_duration_seconds` late-populated (~late-Nov-2025). `compute_ids` may be empty on older rows; `EXPLODE` silently drops NULL/empty arrays (report as a separate "not assessed" bucket).

### `system.lakeflow.pipelines`
The catalog of Lakeflow Declarative Pipelines (DLT), **SCD2**.
- **Grain:** one row per version of a pipeline — `(workspace_id, pipeline_id)` per change. Dedupe to latest by `change_time`.
- **Key columns used:** `workspace_id`, `pipeline_id` (unique only within a workspace), `name`, `pipeline_type`, `created_by`, `run_as`, `change_time`, `delete_time`, and `settings` (nested: `serverless`, `development`, `continuous`, `photon`, `edition` [CORE/PRO/ADVANCED — the *product* edition, not the billing tier], `channel`).
- **Availability:** **Public Preview** — may be disabled or empty on the metastore; a missing table yields `TABLE_OR_VIEW_NOT_FOUND`. UC required. Whether `settings` is a STRUCT (`settings.serverless`) or MAP (`settings['serverless']`) is **unverified** — dot-access may error on some accounts.

### `system.lakeflow.pipeline_update_timeline`
Execution log of pipeline updates (refreshes).
- **Grain:** one row per update *state slice*, hourly-sliced; end row carries `result_state`. `request_id` groups retried/restarted updates.
- **Key columns used:** `workspace_id`, `pipeline_id`, `update_id`, `request_id`, `update_type` (`FULL_REFRESH` / `REFRESH` / `VALIDATE`), `trigger_type` (incl. `RETRY_ON_FAILURE`), `result_state` (`COMPLETED` / `FAILED` / `CANCELED` — one L), `period_start_time` / `period_end_time` (active-second proxy).
- **Availability:** **Public Preview**, UC required, may be empty. Degrade gracefully if disabled.

### `system.billing.usage`
The metered-usage fact table — used here to attach dollars/DBUs to jobs and pipelines.
- **Grain:** one row per entity per usage window per SKU per `record_type`. `record_type` (`ORIGINAL` / `RETRACTION` / `RESTATEMENT`) already nets out to a correct total when summed.
- **Key columns used:** `workspace_id`, `usage_date`, `usage_unit` (filter `= 'DBU'` so bytes/hours/tokens never blend in), `usage_quantity`, `sku_name`, `cloud`, `usage_end_time`, and the `usage_metadata` struct: `job_id` (**no run_id** — DBUs attribute to the job, not the individual run), `dlt_pipeline_id`, `dlt_update_id`, `dlt_maintenance_id` (maintenance/housekeeping DBUs, summed separately).
- **Availability:** GA, UC required, `SELECT` on system needed. All joins use `(workspace_id, job_id)` or `(workspace_id, dlt_pipeline_id)` because those ids are unique only within a workspace.

### `system.billing.list_prices`
List (rack-rate) price reference for estimating dollars.
- **Grain:** one row per `(sku_name, cloud, usage_unit, currency_code)` per price-effectivity window.
- **Key columns used:** `sku_name`, `cloud`, `currency_code`, `usage_unit`, `price_start_time`, `price_end_time` (NULL = currently effective, open interval), and `pricing.effective_list.default` (the list rate — an **estimate only**, not the account's negotiated/discounted price).
- **Availability:** GA, UC required. Joined open-interval on `usage_end_time BETWEEN price_start_time AND price_end_time`.

### `system.compute.clusters`
Cluster inventory, used cross-domain to classify the compute a task ran on.
- **Grain:** one row per version of a cluster — `(workspace_id, cluster_id)`, **SCD2**; dedupe to latest by `change_time`.
- **Key columns used:** `workspace_id`, `cluster_id`, `cluster_source` (`UI` / `API` = all-purpose, vs job-created), `change_time`.
- **Availability:** GA, UC required. Cross-domain join to `job_task_run_timeline.compute_ids`; confirm `compute_ids` is populated on the target workspace.

---

## Queries

### Reliability — runs & failures
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_failed_runs` | Failed-run counts by `(workspace, run_type, trigger_type, result_state, termination_code)` over 30d. | Baseline reliability posture — which trigger types and error codes dominate failures. |
| `lakeflow_termination_taxonomy` | Distinct-run counts grouped by `termination_code` over 30d. | Root-cause breakdown; surfaces quota/limit hits (`WORKSPACE_RUN_LIMIT_EXCEEDED`, `MAX_JOB_QUEUE_SIZE_EXCEEDED`, `CLUSTER_ERROR`). |
| `lakeflow_termination_type_probe` | Runtime discovery of distinct `termination_type` values. | Probe to confirm the (unverified) `termination_type` enum populates before relying on it. |
| `lakeflow_never_started_runs` | Runs where `period_start_time = period_end_time` (never executed), by termination code. | Catches runs killed before launch — capacity, quota, or config problems, not code bugs. |
| `lakeflow_retries_repairs` | Per-job retry counts: attempts, total retries, runs-with-retry. | Flapping jobs that succeed only after repeated retries — hidden instability and wasted compute. |
| `lakeflow_succeeded_with_failed_tasks` | Runs that reported SUCCEEDED but contained a FAILED/ERROR/TIMED_OUT task. | Silent partial failures — a "green" job that actually dropped work. |
| `lakeflow_workload_mix_hours` | Daily run mix by `run_type`/`trigger_type` with execution-seconds. | Understand the job portfolio: scheduled vs submit vs workflow runs, and where hours go. |

### Reliability — queue & startup latency
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_job_queue_time` | Per-job queue seconds (total + p95) with a NULL-queue "not assessed" bucket. | Jobs waiting on capacity — candidates for higher concurrency limits or dedicated compute. |
| `lakeflow_phase_cold_start` | Per-job phase durations (setup/queue/execution/cleanup/run) totals + p95. | Locates cold-start / setup overhead vs actual execution time. |

### Cost & waste
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_failed_jobs_wasted_dbus` | Top failing jobs ranked by a wasted-DBU **proxy** (job DBUs × failed-run share) with the latest failure's termination code. | Prioritizes reliability fixes by dollar impact; the biggest DBU-burning failing jobs first. |
| `lakeflow_pipeline_cost` | Per-DLT-pipeline net DBUs, separate maintenance DBUs, list-$ estimate, update count and active seconds. | Which pipelines cost the most and which over-refresh; splits housekeeping from pipeline logic. |
| `lakeflow_jobs_on_all_purpose` | Job tasks running on `cluster_source IN ('UI','API')` (all-purpose) compute. | All-purpose is billed at a higher SKU than jobs compute — moving these to job clusters saves money. |

### Timeout hygiene
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_jobs_no_timeout` | Active jobs with no (or zero) `timeout_seconds`, plus NULL "not assessed" bucket. | Jobs with no timeout can hang indefinitely and burn compute; a governance gap. |
| `lakeflow_job_tasks_no_timeout` | Active tasks with no/zero task-level `timeout_seconds`. | Finer-grained timeout coverage than the job-level view. |
| `lakeflow_tasks_near_timeout` | Task runs reaching ≥80% of (or exceeding) their configured timeout; p95 exec. | Tasks about to trip their timeout — tune the bound or fix the slowdown before it fails. |

### Pipelines (DLT / Lakeflow Declarative)
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_pipelines_inventory_tier` | Pipeline inventory grouped by type / serverless / development / continuous / edition. | Fleet overview: how many pipelines run serverless, continuous, or in dev mode. |
| `lakeflow_pipeline_update_failures_retries` | Update counts by type/trigger/result with failed and retry-triggered rows. | Pipeline reliability — which pipelines fail refreshes and lean on retry-on-failure. |
| `lakeflow_pipeline_idle_tail_duration` | Per-pipeline updates + active seconds with continuous/development settings. | Continuous/dev pipelines whose clusters linger idle between updates (corroborate with billing idle DBU). |

### Governance
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `lakeflow_job_ownership_orphans` | Per-workspace counts of creator/run-as NULLs, owner mismatches, and orphan candidates. | Orphaned or handed-off jobs, service-principal run-as patterns — ownership accountability. |
| `lakeflow_health_rule_coverage` | Active jobs with vs without a configured `health_rules` entry, plus NULL bucket. | Health-rule coverage: which jobs have no automated failure/duration alerting. |
| `lakeflow_stale_zombie_jobs` | Active jobs whose last run start is >30d ago (or never), flagged `is_stale_30d`. | Dead/zombie job definitions cluttering the workspace — cleanup and audit candidates. |

---

## Notes

- **Date windows.** Most queries use a rolling 30-day lookback (`date_add(current_date(), -30)`); the cost queries parameterize it as `:period_days`. Nearly all reliability/cost queries drop the incomplete current day with `period_end_time < date_trunc('DAY', current_timestamp())` (and billing with `usage_date < current_date()`) so partial-day data never skews totals. `lakeflow_stale_zombie_jobs` deliberately omits this — it is a last-seen lookback, not a sum.
- **End-row filtering is mandatory.** Because `job_run_timeline`, `job_task_run_timeline`, and `pipeline_update_timeline` slice long runs into hourly rows, every metric filters `result_state IS NOT NULL` (the end row) and counts `DISTINCT run_id`/`update_id`. Skipping this double-counts long runs and miscounts retries.
- **SCD2 dedupe is mandatory.** `jobs`, `job_tasks`, `pipelines`, and `clusters` are change-history tables. Always take the latest row per natural key via `QUALIFY ROW_NUMBER() ... ORDER BY change_time DESC`, then `delete_time IS NULL` to exclude deleted objects. Omitting this inflates every count.
- **Ids are workspace-scoped.** `job_id`, `task_key`, `pipeline_id`, `cluster_id`, and `usage_metadata.job_id`/`dlt_pipeline_id` are unique only within a workspace. Every join and grouping keys on `(workspace_id, <id>)` — never the id alone — to avoid cross-workspace fan-out in a multi-workspace metastore.
- **Late-populated columns → "not assessed," never a finding.** Many columns only began populating in late-2025 (`creator_user_name`, `run_as_user_name`, `health_rules`, `queue_duration_seconds`, phase `*_duration_seconds`, task `execution_duration_seconds`, `timeout_seconds`, `termination_type`) or 2024 (`termination_code`). On short-history accounts these are NULL for every row. The queries expose separate `*_null` counters (e.g. `jobs_timeout_null`, `runs_queue_null`, `jobs_creator_null`) so a fully-NULL column degrades to "not assessed — column not yet populated" rather than being read as a violation.
- **DBU attribution is job/pipeline-level, not run-level.** `system.billing.usage.usage_metadata` carries `job_id`/`dlt_pipeline_id` but **no run_id**. `lakeflow_failed_jobs_wasted_dbus` therefore scales job DBUs by the failed-run share — an honest proxy, labelled as such, not exact run-level waste. `WORKFLOW_RUN` compute is attributed to the parent notebook; do not double-count its DBUs against the job.
- **Dollars are list estimates.** `lakeflow_pipeline_cost` multiplies DBUs by `list_prices.pricing.effective_list.default` — a pre-discount list rate, treated as an estimate × discount, never a billed dollar. The CAST path is unverified. Pure duration/queue metrics carry no dollars (Databricks publishes no DBU→$ rate for those).
- **Masking.** Human-readable job/pipeline names are masked to their first two characters (`concat(substr(name,1,2),'****')`) in `lakeflow_pipeline_cost` and `lakeflow_stale_zombie_jobs`. Redacted identities (`__REDACTED__`, FedRAMP workspaces) are normalized to NULL and treated as unavailable, not as a mismatch.
- **Preview / availability gaps are expected.** `system.lakeflow.pipelines` and `pipeline_update_timeline` are Public Preview and may be disabled or empty — a missing table returns `TABLE_OR_VIEW_NOT_FOUND` and the pipeline queries should be skipped, not treated as an error. An account that runs no jobs or pipelines returns an empty (but valid) result. All `system.*` reads require Unity Catalog and `SELECT` granted on the relevant `system` schema.
- **Unverified struct access.** `pipelines.settings.<key>` (dot access) and `pipelines.health_rules` cardinality assume STRUCT/array typing; on some accounts `settings` may be a MAP requiring `settings['key']`. `lakeflow_pipelines_inventory_tier` and `lakeflow_pipeline_idle_tail_duration` flag this as needing per-workspace confirmation.
- **`result_state` failure set.** "Failed" means `result_state IN ('FAILED','ERROR','TIMED_OUT')` consistently across the domain. `SKIPPED`, `CANCELLED`, and `BLOCKED` are intentionally *not* counted as failures.
