# Model Serving & AI

> 📖 **Guided HTML tour:** [`docs/index.html`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. *(Phase 1 covers the top 10 across cost, jobs, compute, performance and governance; this domain's queries are documented in a later phase.)*

This domain answers: *what is running on Databricks Model Serving, how much traffic and token throughput each endpoint handles, which endpoints are dormant (paying but idle), and whether AI Gateway is seeing abuse — error/rate-limit spikes, latency blowups, or runaway token volume.* The queries read the request/token telemetry tables (`system.serving.endpoint_usage`, `system.ai_gateway.usage`) and join them to the serving configuration dimension (`system.serving.served_entities`). None of these tables carry dollars — DBU cost for serving lives in `system.billing.usage`; these are request/token counters used to right-size and govern serving spend, not to compute it.

## System tables used

### system.serving.endpoint_usage
The request-level telemetry table for Model Serving endpoints — the fact table of this domain.

- **Grain:** one row **per inference request** (CONFIRMED against the AI Gateway usage-schema docs, 2026-06-21). There is **no `request_count` column** — request volume is `COUNT(*)`.
- **Key columns used:**
  - `request_time` (TIMESTAMP) — when the request was served; drives every date window.
  - `workspace_id` — workspace the endpoint lives in.
  - `served_entity_id` — the served entity that handled the request. **This table carries `served_entity_id`, not `endpoint_id`** — endpoint identity is resolved by joining to `served_entities`.
  - `status_code` (INTEGER) — HTTP status; 2xx = success, everything else = error.
  - `input_token_count` / `output_token_count` (LONG) — per-request token throughput (separate magnitude from request counts, never summed together).
- **Availability:** Empty unless **Model Serving is enabled and in use** on the metastore; requires Unity Catalog and `SELECT` on `system.serving.*`. An account that has never served a model yields a valid but empty result (queries degrade to `not_assessed`, never a fake "all endpoints dormant"). Note: two of the older queries here assume alternate column names (`request_count`, `served_entity_input_tokens`, `served_entity_output_tokens`) that are **not** the confirmed schema — see Notes.

### system.serving.served_entities
The configuration/dimension table describing what each endpoint serves (a model, a foundation-model route, an external model, etc.).

- **Grain:** **change-history** — one row per configuration change of a served entity, **not** one row per entity. Every query here deduplicates to the latest row per `(workspace_id, endpoint_id, served_entity_id)` via `ROW_NUMBER() … ORDER BY change_time DESC` before joining, so a renamed/reconfigured entity is not double-counted.
- **Key columns used:**
  - `workspace_id`, `endpoint_id`, `endpoint_name` — endpoint identity (the human-readable name lives here, not in `endpoint_usage`).
  - `served_entity_id`, `served_entity_name` — the served entity within the endpoint (an endpoint can host multiple).
  - `entity_type`, `entity_name`, `entity_version` — what is being served (e.g. a registered model + version, or an external/foundation model).
  - `change_time` (TIMESTAMP) — config-change timestamp; used both to dedupe and, in the dormant query, as a recency floor (`latest_change_time`) so a newly-created endpoint inside the window is not mislabeled dormant.
- **Availability:** Same gating as `endpoint_usage` — Model Serving in use, Unity Catalog, `SELECT` on `system.serving.*`. `entity_creator`/creation-flag columns are assumed but **not verified**.

### system.ai_gateway.usage
Request telemetry captured by **Mosaic AI Gateway** — the governance/proxy layer that fronts serving endpoints for rate-limiting, usage tracking, and safety.

- **Grain:** assumed **per-request (or per aggregated request bucket)** for a gateway-fronted endpoint. Column shape is **NEEDS WORKSPACE CONFIRMATION** — the query is written to the documented/assumed shape and guards every column downstream.
- **Key columns used (assumed):**
  - `request_time` (TIMESTAMP), `workspace_id`, `endpoint_name`.
  - `requester` — the calling principal (an individual **user or service principal**, never a team — do not relabel).
  - `status_code` (HTTP) — 2xx = success, `429` = rate-limit/quota hit, other = error.
  - `request_count`, `input_tokens`, `output_tokens` — volume and token throughput.
  - `request_duration_ms` — end-to-end latency (column name uncertain); summarized via `percentile_approx(col, 0.5/0.95)`, deliberately avoiding the `PERCENTILE(col, 95)` mistake.
- **Availability:** **Empty unless AI Gateway is explicitly enabled on an endpoint** — this is opt-in per endpoint, not automatic with serving. Preview / evolving schema; requires Unity Catalog and `SELECT` on `system.ai_gateway.*`. Column names above are **unverified for this workspace**; an absent column degrades that one metric to "unknown" rather than erroring the whole finding. A 429/error row is an abuse/quota **signal**, not proof of misuse.

---

**Per-query documentation** — what each query does, why it matters, how to read every output column, an illustrative sample of the result, and the caveats — lives in the guided HTML tour: **[read it rendered →](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#d-serving)**. The `.sql` files in this folder are the source of truth.

