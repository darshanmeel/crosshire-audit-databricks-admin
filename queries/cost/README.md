# Cost & Billing

> 📖 **Guided HTML tour:** [`docs/index.html`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. From this domain: [`cost_dollarized_by_sku_day`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-cost_dollarized_by_sku_day), [`cost_by_job`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-cost_by_job), [`cost_actual_vs_list_by_sku`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-cost_actual_vs_list_by_sku), [`cost_chargeback_by_tag`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-cost_chargeback_by_tag), [`cost_premium_serverless_photon`](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#q-cost_premium_serverless_photon). *(Phase 1 = top 10; more in phases.)*

This domain answers the core FinOps question for a Databricks account: **where does the money go, and can we trust the number?** It reads the `system.billing.*` price and usage tables to break spend down by SKU, product line, workspace, compute resource, job, notebook, serving endpoint, identity, and tag; to convert raw DBU consumption into list and negotiated dollars; and to prove that billing corrections do not double-count. It also reaches into `system.access.workspaces_latest` for a workspace-id → name lookup so every per-workspace cut reads as `dev / uat / prod` instead of an opaque numeric id.

Every query is **copy-paste SQL** run in a Databricks SQL warehouse. They take a single bind parameter `:period_days` (the trailing look-back window in days). Nothing here writes; nothing depends on a dashboard or app.

---

## System tables used

### `system.billing.usage`
The account's billed-consumption fact table and the backbone of almost every query in this folder.

- **Grain:** one row per (usage record) — a metered slice of consumption for a given account/workspace, SKU, usage date/hour, compute resource, and `record_type`. A single logical charge can appear as multiple rows across `record_type` values (ORIGINAL, then a later RETRACTION/RESTATEMENT correction), so a *net* figure must SUM `usage_quantity` across **all** record types — never filter to `ORIGINAL`.
- **Key columns these queries use:**
  - `usage_date` (DATE, the recommended partition/filter column), `usage_end_time` (TIMESTAMP, used to pick the active price window), `ingestion_date` (load date, distinct from usage_date — drives the freshness/lag caveat).
  - `usage_quantity` — the metered amount in `usage_unit`. **This is DBUs/bytes/hours/tokens, NOT dollars.**
  - `usage_unit` — `DBU`, `STORAGE_SPACE` bytes, hours, `TOKEN`, etc. Queries that price against a per-DBU rate filter `usage_unit = 'DBU'` so they never blend units.
  - `usage_type` — confirmed enum: `COMPUTE_TIME, STORAGE_SPACE, NETWORK_BYTE, NETWORK_HOUR, API_OPERATION, TOKEN, GPU_TIME, ANSWER`.
  - `record_type` — `ORIGINAL / RETRACTION / RESTATEMENT` (the correction/trust signal).
  - `sku_name`, `billing_origin_product` (product line: `JOBS / SQL / DLT / MODEL_SERVING / VECTOR_SEARCH / DEFAULT_STORAGE / …` — populated but with **no published closed enum**, so literals like `DEFAULT_STORAGE` are treated as unverified; a blank value is "unattributed", not zero), `cloud`, `currency_code`, `workspace_id` (NULL for account-level SKUs — kept as "not workspace-attributable"), `account_id`.
  - `custom_tags` (MAP — compute-resource and serverless-usage-policy tags; keys are customer-defined, never hardcode them).
  - `usage_metadata` (STRUCT): `cluster_id`, `warehouse_id`, `instance_pool_id`, `job_id`, `job_run_id`, `notebook_id`, `endpoint_id`, `endpoint_name`, `storage_api_type`, `catalog_id`, `metastore_id` (AWS-only), `source_region`/`destination_region` (always NULL on GCP), `networking_client`, `recipient_id`, `usage_policy_id`, `budget_policy_id` (deprecated). These are sparse/conditional — populated only for the compute type that generated the row (e.g. `job_id` only for jobs compute, `notebook_id` only for notebook-attached interactive usage), otherwise NULL.
  - `identity_metadata` (STRUCT): `run_as`, `owned_by` (SQL-warehouse usage only), `created_by`. Sparse, and replaced with the literal `'__REDACTED__'` in FedRamp workspaces — treat `'__REDACTED__'`/NULL as "identity unavailable".
  - `product_features` (STRUCT): `is_serverless`, `is_photon`, `jobs_tier`, `sql_tier`, `dlt_tier`, `performance_target`, `serving_type`. Sparse — subfields are NULL where the choice doesn't apply.
- **Availability:** GA and generally the most reliably-populated billing table. Requires **Unity Catalog** (system schemas are UC-only) and that `system.billing` be enabled on the metastore, plus `SELECT` granted on the table. A feature the account doesn't use simply yields no rows for it (e.g. no serving = no `MODEL_SERVING` rows), which is a valid empty result, not `$0`.

### `system.billing.list_prices`
The public **list (pre-discount) price** history per SKU. Joined to `usage` to dollarize DBUs.

- **Grain:** one row per SKU **price change** — i.e. a `[price_start_time, price_end_time)` validity window per (sku_name, cloud, currency_code, usage_unit). `price_end_time IS NULL` means the currently-active price.
- **Key columns:** `price_start_time`, `price_end_time`, `account_id`, `sku_name`, `cloud`, `currency_code`, `usage_unit`, and the `pricing` STRUCT — `pricing.default` (typed **STRING** in docs) and `pricing.effective_list` (typed only as an **object** in docs; the nested `pricing.effective_list.default` scalar path and its numeric cast are **unverified**), plus `pricing.promotional`. Queries collect these raw as JSON strings so collection survives struct drift and dollarize in-engine.
- **Availability:** GA, UC-required, `SELECT` needed. Small table. Because the join is a point-in-time window match, the price predicate **must** be `(price_end_time IS NULL OR usage < price_end_time)` — using only `usage < price_end_time` silently zeroes recent usage.

### `system.billing.account_prices`
The account's **actual negotiated** price history — the same shape as `list_prices` but carrying the discounted rate the account really pays.

- **Grain:** one row per SKU negotiated-price change (`[price_start_time, price_end_time)` window per sku_name + cloud + currency_code + usage_unit). `price_end_time IS NULL` = currently-active negotiated price.
- **Key columns:** `price_start_time`, `price_end_time`, `account_id`, `sku_name`, `cloud`, `currency_code`, `usage_unit`, and `pricing.default` (the negotiated rate; typed **STRING**, numeric cast unverified). **Important:** this table has **only** `pricing.default` — there is **no** `pricing.effective_list` here (that lives on `list_prices`). Actual-vs-list compares `account_prices.pricing.default` against `list_prices.pricing.effective_list.default`.
- **Availability:** GA, UC-required, `SELECT` needed. Multi-cloud/multi-currency accounts have several rows per `sku_name`, so joins must key on cloud + currency_code + usage_unit + sku_name, not `sku_name` alone.

### `system.billing.attributed_usage`
Databricks' **fair-split allocation** of shared-pool DBUs back to the consuming entity.

- **Grain:** one row per attributed usage slice (assumed to mirror `system.billing.usage`: `usage_date`, `usage_quantity`, `usage_unit`, `billing_origin_product`, `cloud`, …).
- **Key columns used:** `usage_date`, `cloud`, `billing_origin_product`, `usage_unit`, `usage_quantity`.
- **Availability:** **Coverage is DBSQL (SQL warehouses) ONLY** — it does not track jobs/DLT/all-purpose. Preview/newer; exact schema **not verified** on-workspace (a missing column errors the query, which the engine degrades to "not assessed" rather than fabricating a 0). Only meaningful when both sides of the raw-vs-attributed comparison are scoped to `billing_origin_product = 'SQL'`.

### `system.billing.cloud_infra_cost`
The **cloud provider's own infrastructure charge** (instance hours, network/egress) that sits *outside* DBU pricing — the 10–25% of spend the `usage` table misses.

- **Grain:** one row per infra cost slice, aggregated here by the table's own dimensions `usage_date` / `cloud` / `currency_code`.
- **Key columns (assumed, unverified on-workspace):** `usage_date`, `cloud`, `currency_code`, and `cost` (DOUBLE — a **real billed dollar** in the row's currency, unlike `usage_quantity`).
- **Availability:** largely **AWS-only**, Preview, and **empty on many accounts** (requires the cloud-provider cost export / network policy to be enabled). An empty result must render "not assessed", never `$0`. **Do not** LEFT JOIN compute change-history tables (warehouses/clusters) into this rollup — they fan out rows and double-count `SUM(cost)`; dedupe to latest-row-per-id first in a separate step if attribution is needed.

### `system.access.workspaces_latest`
A tiny workspace-id → name lookup, kept deliberately separate from billing.

- **Grain:** one row per workspace (latest snapshot).
- **Key columns:** `workspace_id`, `workspace_name`, `status` (active vs deleted).
- **Availability:** part of `system.access` (UC-required, `SELECT` needed; may not be enabled on every metastore). It is intentionally **not** joined into `billing.usage` at query time — if it's unavailable, only NAME resolution is lost and every per-workspace cost figure (keyed on `workspace_id`) still works, falling back to the numeric id.

---

## Queries

### Totals, dollarization & pricing basis
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_totals_by_sku_day` | Net DBU/units per usage_date × workspace × SKU × product × usage_type, split by record_type and is_serverless | The base rollup for cost totals, per-workspace (dev/uat/prod) split, serverless mix, restatement %, and anomaly time series |
| `cost_dollarized_by_sku_day` | Net DBUs **×** list rate → `net_list_cost` per SKU/day (list-price join) | Turns DBUs into dollars for headline cost/anomaly views (list, pre-discount; `list_rate` path unverified — dollarize off the raw artifact until confirmed) |
| `pricing_list_prices_raw` | Raw list-price rows (default + effective_list + promotional as JSON) | Per-SKU rate basis so the engine prices each usage row in its correct time window — replaces a hardcoded $/DBU |
| `cost_account_prices_raw` | Raw negotiated-price rows (`pricing.default` per SKU window) | The account's real negotiated rate basis, feeding actual-vs-list and discount-realization |
| `cost_actual_vs_list_by_sku` | Net DBUs, `net_negotiated_cost`, and `net_list_cost` per SKU (usage ⋈ account_prices ⋈ list_prices) | Quantifies negotiated-discount realization %; how much the discount actually saves per SKU |
| `cost_actual_vs_list_by_sku` (headline) | — see above — | savings_usd figure on the Pricing & Allocation tab (labelled negotiated/list-unverified until casts confirmed) |

### Where the money goes (product / resource / workload)
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_by_billing_origin_product` | Net usage per product line (JOBS/SQL/DLT/MODEL_SERVING/…) × usage_unit × cloud | The product-mix Pareto — which product lines dominate the bill |
| `cost_by_compute_resource` | Net DBUs per cluster_id / warehouse_id / instance_pool_id per day/workspace | Dollarizes cluster right-sizing and idle-warehouse waste; finds expensive under-used compute (names resolved via config tables downstream) |
| `cost_by_job` | Net DBUs and distinct run count per job_id per day/workspace, classic vs serverless | Which jobs cost most; sizes the jobs-on-all-purpose placement premium and failed-run waste |
| `cost_by_notebook` | Net DBUs per notebook_id (interactive/all-purpose) per day/workspace | Puts a $ on ad-hoc human work; flags a single runaway notebook (populates only for notebook-attached usage) |
| `cost_default_storage_dsu` | Net storage usage per SKU × `storage_api_type` (TIER_1/TIER_2) × catalog_id | Default-storage/DSU cost and API-tier breakdown (uses the confirmed `storage_api_type IS NOT NULL` signal, not an unverified product literal) |

### AI / serving / vector / networking spend
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_by_serving_endpoint` | Net DBUs per model-serving + vector-search endpoint per day, by usage_type | Sizes the MODEL_SERVING + VECTOR_SEARCH share of the bill by endpoint so the biggest/fastest-growing get right-sized first |
| `cost_serving_mode_by_endpoint` | Per-endpoint model-serving spend with **inferred** cost mode (pay-per-token vs provisioned vs scale-from-zero LAUNCH) + bounded list cost | Reveals cost mode from billed signals (scale-to-zero/workload config is NOT in system tables — API only) |
| `cost_vector_search_spend` | Vector Search spend by endpoint split into serving vs ingest vs DSU storage, + list cost | Finds idle Vector Search endpoints (joined to access traffic in-engine); STORAGE_SPACE (DSU) vs serving DBUs kept separate |
| `cost_genai_token_gpu` | Net TOKEN / GPU_TIME / ANSWER usage per SKU × serving_type × endpoint | GenAI/token spend and AI-cost anomaly detection (token/GPU rows priced on their own SKU, never the DBU rate) |
| `cost_networking_egress` | Net NETWORK_BYTE / NETWORK_HOUR usage per region pair × client × recipient | Closest billed data-egress signal, incl. Delta Sharing egress by recipient (regions NULL on GCP; reconcile with cloud export) |
| `cost_cloud_infra` | Net `cost` (real dollars) per day × cloud × currency from the cloud-infra table | The non-DBU cloud infra + egress spend DBUs miss (AWS-mostly; empty ⇒ "not assessed") |

### Efficiency & premium levers
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_premium_serverless_photon` | Net DBUs split by is_serverless / is_photon / jobs_tier / sql_tier / dlt_tier / performance_target | Sizes the serverless-vs-classic, Photon, DLT-tier, and perf-optimized-serverless premiums (dollarize the delta via list_prices) |
| `cost_dbsql_allocation_gap` | Raw-DBSQL vs attributed-DBSQL DBUs in one labelled result (UNION ALL, both scoped to SQL) | Finds cross-subsidized shared SQL-warehouse pools / unattributed DBU % (never joins run_as = executed_by — different identities) |

### Chargeback, tagging & policy hygiene
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_chargeback_by_identity` | Net DBUs per identity (user vs service_principal, masked run_as/owned_by/created_by) per day/workspace/product | Identity-level chargeback; SP-vs-human split; untagged-but-attributable spend (treats `__REDACTED__`/NULL as unknown) |
| `cost_chargeback_by_tag` | Net DBUs per custom_tags key/value (OUTER explode keeps untagged rows) per day/workspace/product | % untagged spend and tag drift; exposes an umbrella tag that covers 100% of DBUs yet gives no team-level chargeback |
| `cost_usage_policy_coverage` | Net serverless DBUs by policy_coverage (usage_policy/budget_policy_legacy/none) × tag_coverage per workspace/product | % serverless spend with no usage policy; splits the fix by product (notebook → policy, warehouse → tag) |

### Trust & workspace lookup
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `cost_restatement_trust_metric` | Net vs original vs retracted-abs vs restatement DBUs + max ingestion_date, per cloud | The "% of usage later restated" trust metric; proves the net does not double-count corrections; freshness/lag note |
| `cost_workspace_names` | workspace_id → workspace_name + status | Makes every per-workspace cut read as dev/uat/prod; kept separate so missing access table only loses names |

---

## Notes

- **Date window:** every consumption query filters `usage_date >= dateadd(day, -:period_days, current_date()) AND usage_date < current_date()` — a trailing `:period_days`-day window that **excludes today** (today's billing is incomplete). The two raw price tables (`pricing_list_prices_raw`, `cost_account_prices_raw`) and `cost_workspace_names` are **not** windowed — they pull full price/lookup history. Treat the **most recent day's** figures as provisional due to billing populate lag; `ingestion_date` (≠ `usage_date`) is the freshness signal.
- **DBUs are not dollars.** `usage_quantity` is DBUs/bytes/hours/tokens. Only `cost_cloud_infra.cost` is a real billed dollar; everything else must be multiplied by a price rate to become money. Different `usage_unit` families (DBU vs STORAGE_SPACE bytes vs TOKEN vs hours) are **never summed together**.
- **Net corrections, always.** SUM `usage_quantity` across all `record_type` values — RETRACTION/RESTATEMENT already net out ORIGINAL. Never re-net downstream and never filter to `ORIGINAL` for a net rollup.
- **Price-window predicate.** For every price join, `price_end_time IS NULL` means "currently active" — the predicate must be `(price_end_time IS NULL OR usage < price_end_time)`. Dropping the NULL branch silently zeroes recent usage.
- **Unverified price paths.** `list_prices.pricing.effective_list.default` and `pricing.default` are documented as object/STRING; the numeric CAST to DOUBLE is **not verified** on-workspace. Queries that rely on them (`cost_dollarized_by_sku_day`, `cost_actual_vs_list_by_sku`, `cost_serving_mode_by_endpoint`, `cost_vector_search_spend`, `cost_account_prices_raw`) carry every derived dollar as **list/negotiated-unverified** and never promote it to a billed headline; the safe fallback is to dollarize in-engine off the raw JSON artifacts.
- **Masking.** PII-bearing string columns are masked in the SQL itself: emails → `ab****@****`, non-UUID names → `ab****`, serving `endpoint_name` → first-2-chars + `****`; UUIDs and `__REDACTED__` are passed through unchanged. Drop the mask CASE (or run a `--no-redact` variant) for an internal user leaderboard.
- **Multi-cloud / multi-currency.** Join price tables on cloud + currency_code + usage_unit + sku_name — never `sku_name` alone, or you fan out or mis-price accounts with several rows per SKU.
- **Empty ≠ error ≠ $0.** A feature the account doesn't use (serving, vector search, Delta Sharing, cloud-infra export) returns a valid empty result; a Preview/disabled or non-permissioned table can raise `TABLE_OR_VIEW_NOT_FOUND`. Both are expected — the engine degrades those sources to "not assessed" rather than reporting a fabricated zero.
- **Names live elsewhere.** Billing has no cluster/warehouse/job/notebook/workspace **names** — resolve `cluster_id`/`warehouse_id` via compute config tables, `job_id` via `system.lakeflow.jobs` (SCD2, latest by change_time), and `workspace_id` via `cost_workspace_names`, all downstream of these rollups.
