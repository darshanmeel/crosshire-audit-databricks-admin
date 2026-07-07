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

**Per-query documentation** — what each query does, why it matters, how to read every output column, an illustrative sample of the result, and the caveats — lives in the guided HTML tour: **[read it rendered →](https://darshanmeel.github.io/crosshire-audit-databricks-admin/#d-cost)**. The `.sql` files in this folder are the source of truth.

