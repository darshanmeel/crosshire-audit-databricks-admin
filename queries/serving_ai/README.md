# Model Serving & AI

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

## Queries

| Query id | What it returns | Why an admin cares / how to use |
|---|---|---|
| `compute_serving_endpoint_usage` | Per day × endpoint × served-entity: total / success / error requests and input/output token totals, with endpoint & entity names joined from `served_entities`. | Endpoint health baseline — spot endpoints with high error rates or surprising token throughput; the workhorse view of serving activity. (depth: fact × deduped-dimension join, daily rollup.) |
| `serving_endpoint_traffic_by_endpoint` | Per endpoint over the window: request `COUNT(*)`, success/error split, token totals, and `last_request_date`. **The one CONFIRMED-schema query** (uses `COUNT(*)`, `input_token_count`/`output_token_count`, joins on `served_entity_id` only). | Cross request volume against the billed serving mode (provisioned-throughput vs pay-per-token) to catch cost-mode mismatches. (depth: window rollup, confirmed columns.) |
| `compute_serving_dormant_endpoints` | Every served entity (latest config row) LEFT-JOINed to windowed usage, so entities with no traffic keep `total_requests = 0` and `last_request_date = NULL`. | Find endpoints that are provisioned but received **no requests in N days** — prime candidates to scale to zero or delete. NULL usage = the dormant signal (means "no traffic in window", not "never used"). (depth: dimension-preserving LEFT JOIN + recency floor.) |
| `compute_ai_gateway_usage` | Per day × workspace × endpoint × requester: total / success / rate-limited (429) / error requests, input/output tokens, and p50/p95/max latency. | Detect AI Gateway abuse — error or rate-limit spikes, latency blowups, or a single requester driving runaway token volume. (depth: multi-dimension rollup + approx-percentile latency; schema unverified.) |

## Notes

- **Date window:** every query is parameterized by `:period_days` and uses the half-open range `request_time >= dateadd(day, -:period_days, current_date()) AND request_time < current_date()` (whole days, excludes today's partial data).
- **Masking:** `endpoint_name` and `served_entity_name` are truncated to their first 2 chars + `****`. In `compute_ai_gateway_usage`, `requester` is masked by type — emails to `xx****@****`, raw GUIDs (service principals) left intact, other principals truncated; `__REDACTED__` sentinels are passed through untouched.
- **Empty ≠ broken:** if Model Serving or AI Gateway is not in use, these tables are empty or absent (`TABLE_OR_VIEW_NOT_FOUND`). Collection preflight skip-sentinels the table and the finding degrades to `not_assessed` — never a fabricated zero.
- **Schema confidence split (important gotcha):** only `serving_endpoint_traffic_by_endpoint` is CONFIRMED. The other two serving queries were written before confirmation and still assume `request_count`, `served_entity_input_tokens`/`served_entity_output_tokens`, and a join on `endpoint_id` — the confirmed reality is **one row per request (no `request_count`)**, token columns `input_token_count`/`output_token_count`, and `endpoint_usage` carrying only `served_entity_id`. Treat their token/volume numbers as needing re-validation against the confirmed schema. `compute_ai_gateway_usage` column names are entirely unverified.
- **Not a cost source:** these tables count requests and tokens, not DBUs/dollars. Serving spend comes from `system.billing.usage`; use these counts to right-size and govern, then cross to billing for the money figure.
- **`requester` is a principal, not a team.** A 429 or error row is a signal to investigate, not a proven violation.
