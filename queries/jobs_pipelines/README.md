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

**Per-query documentation** — what each query does, why it matters, how to read every output column, an illustrative sample of the result, and the caveats — lives in the guided HTML tour: **[read it rendered →](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#d-jobs)**. The `.sql` files in this folder are the source of truth.

