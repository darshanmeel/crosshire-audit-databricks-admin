# Table coverage — what populates each system table, and why it would be empty

Every query in this library reads Databricks **system tables** (`system.*`). A query can return
**nothing** for reasons that are *not* bugs — the runner records these as **`NOT_ASSESSED`**, never a
fake `0` (see the [runner](tools/run_audit.py) and the hosted
[Coverage & troubleshooting guide](https://learn.crosshire.ch/learn/tech/databricks/audit/coverage)).
This file is the in-repo reference for **why a given table is empty**: what writes rows into it, and
what has to be true first.

## The three universal reasons a system table is empty

Before the per-table detail, almost every "empty table" is one of these:

1. **Unity Catalog isn't enabled.** System tables live in the UC `system` catalog. No UC-enabled
   workspace (metastore on Privilege Model v1.0) → no system tables at all.
2. **The system *schema* isn't enabled, or you can't read it.** System schemas are enabled
   **per-schema** (mostly opt-in) by an account/metastore admin, and reads are **privilege-scoped** —
   a non-admin without `USE CATALOG` on `system` + `USE SCHEMA` + `SELECT` sees *zero rows*, not an error.
3. **The feature was never used, or not in your window.** A table only has rows once the underlying
   feature actually runs (a job executed, an endpoint got traffic, Predictive Optimization did work),
   and only within its retention window.

### Which system schemas are on by default vs. opt-in

| Schema | Enabled? | Notes |
|---|---|---|
| `billing` | **Always on** | Cannot be disabled; the account billing baseline. |
| `compute` | **Default-on** (since the March 2025 release) | On in all UC workspaces. |
| `access`, `query`, `serving`, `storage`, `lakeflow`, `ai_gateway` | **Opt-in** | Enabled per-schema via the **system-schemas API** (`databricks system-schemas enable <metastore_id> <schema>`) by an account/metastore admin. |
| `information_schema` | **Auto-provisioned** | Exists in every UC catalog; no enable step. |
| `data_classification` | **Opt-in + per-catalog** | Schema enabled *and* Data Classification turned on per catalog. |

> **Preview status is per-*table*, not per-schema.** GA: lineage, billing, most of compute, lakeflow
> jobs/timelines, information_schema. Public Preview: `query.history`, `serving.*`, `storage.*`,
> `access.audit`/network/`workspaces_latest`, `lakeflow.pipelines*`, `ai_gateway.usage` (Beta).

---

## Query lineage — which queries depend on each table

The library's own dependency graph is generated **dbt-style** from the queries' `reads:` headers — purely
the `system.*` tables and the 96 queries, **no external data** — by `tools/build_lineage.py` into
[`lineage/`](lineage/): dbt [`sources.yml`](lineage/sources.yml), the full sources→queries DAG plus a
per-source reverse index in [`query_lineage.md`](lineage/query_lineage.md), and machine-readable
[`query_lineage.json`](lineage/query_lineage.json). It regenerates with the manifest and is checked in CI.

**96 queries read 39 distinct system tables.** Read this beside each table's "why it would be empty" below:
it tells you *how many findings go dark* if a given table is empty or not enabled. The heaviest dependencies:

| System table | Queries | If empty / not enabled… |
|---|--:|---|
| `system.billing.usage` | 35 | most of the cost domain + every `$`-annotated finding goes dark |
| `system.billing.list_prices` | 22 | all list-price `est_usd_*` estimates disappear (DBU columns still show) |
| `system.query.history` | 12 | the whole `performance` domain (Preview; SQL-warehouse/serverless only) |
| `system.lakeflow.job_run_timeline` | 11 | most job reliability / wasted-DBU findings |
| `system.storage.predictive_optimization_operations_history` | 5 | the storage-optimization findings |
| `system.serving.endpoint_usage` / `served_entities` | 3 each | the serving usage / idle-endpoint findings (Preview; tracking-gated) |

The full reverse index (every table → its exact queries) and the system-table **join graph** (which system
tables are read *together* in a query — the closest thing to system-table lineage the queries express) are
in [`lineage/query_lineage.md`](lineage/query_lineage.md).

---

## Per-table reference

### `system.access` — audit, lineage, network *(schema is opt-in; reads are admin/privilege-scoped)*

| Table | Populated by | Empty when… |
|---|---|---|
| `audit` | One row per auditable platform event (logins, UC data access, jobs, SQL warehouse start/stop, secrets, Delta Sharing…). | `access` schema not enabled; you're a non-admin without `SELECT`; account-level events carry `workspace_id = 0` so a workspace filter hides them; **notebook/command events need *verbose audit logging* on**; outside retention. |
| `table_lineage` | One row per UC read/write UC can **infer** (jobs, notebooks, DBSQL, pipelines, dashboards). | No UC activity; work ran via unsupported paths (Jobs `runs-submit`/`spark-submit`, RDDs, JDBC, UDFs, global temp views, path-only refs); older than the **1-year** window. |
| `column_lineage` | One row per inferable **column→column** derivation. | All `table_lineage` reasons + literal-only writes (no source column); Lakeflow pipeline column lineage needs **DBR 13.3 LTS+**. |
| `inbound_network` | One row per **denied** inbound request under a context-based **ingress** policy (dry-run logs would-be denials). | No ingress policy, or none has denied anything; all inbound allowed; Enterprise tier + Preview not configured. |
| `outbound_network` | One row per **denied** serverless **egress** under a network policy. | No egress policy / nothing blocked; workloads on **classic (non-serverless)** compute (not covered); dry-run logging off. |
| `workspaces_latest` | Databricks-maintained inventory: one row per **active** workspace. | UC/schema not enabled or no privilege; deleted workspaces are removed (absent, not zeroed). |

### `system.ai_gateway`

| Table | Populated by | Empty when… |
|---|---|---|
| `usage` | Requests routed through the **Unity AI Gateway (Beta)** — token usage, latency, routing. *(Exists in this environment.)* | **AI Gateway usage tracking / Unity AI Gateway never enabled** (the #1 reason); region not supported; **account-admin-only read**; no gateway traffic in the window. Classic serving usage instead lands in `system.serving.endpoint_usage`. |

### `system.billing` *(always on; essentially never empty for an active account)*

| Table | Populated by | Empty when… |
|---|---|---|
| `usage` | Hourly aggregated row for **every** billable usage in the account (all compute, serving, vector search, storage, networking, apps…). | Almost never — usually a **privilege** gap, brand-new account, ingestion lag, or over-restrictive filters. |
| `list_prices` | Databricks-maintained SKU list-price history (`price_end_time` NULL = current). | Only if you lack `SELECT`, or filter to a SKU/currency with no price rows. |
| `attributed_usage` | Fair-split attribution of shared usage (DBSQL). | Present in this environment; if absent elsewhere it's a Preview table not enabled. Use `usage.custom_tags` / `usage_metadata` for attribution. |
| ~~`account_prices`~~, ~~`cloud_infra_cost`~~ | **Do not exist** — not real system tables. | Always. The queries that once named these now source from `list_prices` / `usage`. |

### `system.compute` *(default-on; classic compute vs SQL warehouses split)*

| Table | Populated by | Empty when… |
|---|---|---|
| `clusters` | SCD2 config history of **classic** all-purpose/jobs/pipelines clusters. | Only serverless / SQL warehouses used (both **excluded**); clusters deleted before 2023-10-23 are absent. |
| `node_timeline` | Per-minute CPU/mem per node for classic compute. | **Nodes that ran < ~10 min may not appear**; serverless/SQL-warehouse only; narrow window. |
| `node_types` | Static regional catalog of node/instance specs. | Effectively never (schema/privilege only). |
| `instance_pools` | SCD2 config history of instance pools. | No pools ever created. |
| `instance_events` | Per-instance state transitions of classic compute. | **SQL-warehouse placement events are excluded**; serverless/DBSQL-only accounts see nothing. |
| `warehouses` | SCD2 config snapshots of **SQL warehouses** (CLASSIC/PRO/SERVERLESS). | No SQL warehouses ever created (deletes keep a `delete_time`, so they stay). |
| `warehouse_events` | SQL-warehouse lifecycle/scaling events. | No DBSQL activity; classic/serverless-only accounts. |

### `system.lakeflow` *(jobs/timelines GA; pipelines Preview)*

| Table | Populated by | Empty when… |
|---|---|---|
| `jobs` / `job_tasks` | SCD2 definitions of Lakeflow Jobs / their tasks. | No jobs created; only one-time `SUBMIT_RUN`/`WORKFLOW_RUN` (which **skip** these dimension tables). |
| `job_run_timeline` / `job_task_run_timeline` | Actual job / task **runs** (incl. submit & workflow runs). | No runs, or none in the **365-day** window. |
| `pipelines` / `pipeline_update_timeline` | Lakeflow Declarative (DLT) pipeline definitions / updates. | No pipelines created / no updates run; Preview region lag. |

### `system.query`

| Table | Populated by | Empty when… |
|---|---|---|
| `history` | One row per query on a **SQL warehouse** *or* on **serverless** compute (notebooks/jobs). | `query` schema not enabled; **classic all-purpose/job clusters are NOT captured**; serverless not enabled; admin-only read. (`statement_text`/`error_message` blank ⇒ customer-managed-key encryption without a key config in the system catalog.) |

### `system.serving` — Model Serving *(see the endpoint deep-dive below)*

| Table | Populated by | Empty when… |
|---|---|---|
| `endpoint_usage` | One row per request to a **Model Serving** endpoint with **AI Gateway usage tracking** on. | Usage tracking not enabled per endpoint; no traffic; only **vector search / feature serving / agent** endpoints exist (not tracked); route-optimized custom endpoints (unsupported). |
| `served_entities` | Metadata for entities served behind those endpoints (`served_entity_id` join key). | No endpoints/served entities configured; schema not enabled. Holds rows even with zero traffic. |

### `system.storage` *(Preview)*

| Table | Populated by | Empty when… |
|---|---|---|
| `predictive_optimization_operations_history` | One row per **Predictive Optimization** op (COMPACTION/VACUUM/ANALYZE/CLUSTERING…) on a UC **managed** table. | PO not enabled/rolled out (ON by default for accounts ≥ 2024-11-11; older accounts rolling out to ~Aug 2026); region unsupported; only external tables; PO found nothing to do; up-to-2h lag (24h for cost). |
| `table_metrics_history` | Daily per-table storage snapshot (active bytes/files, PO-enabled flag). | Feature not rolled out to your account/region; no snapshot yet for the date; no UC tables. |

### `system.information_schema` *(auto-provisioned; privilege-aware)*

| Table | Populated by | Empty when… |
|---|---|---|
| `tables` | One row per UC table/view. | You lack privilege on the objects (privilege-aware); `hive_metastore` excluded. |
| `column_masks` / `row_filters` | One row per **manually applied** column mask / row filter (`ALTER … SET MASK/ROW FILTER`). | No manual masks/filters — **ABAC tag-based policies do NOT appear here** (list them via the UC REST API); or masks exist only on tables you can't see. |
| `column_tags` / `table_tags` | One row per tag assigned to a column / table. | Tagging not adopted; tags only on tables you can't access. |
| `catalog_/schema_/table_privileges` | One row per `GRANT` at that level. | No explicit grants at that level on objects you can see (inherited/owner grants may sit at a different level). |

### `system.data_classification` *(Preview; opt-in per catalog)*

| Table | Populated by | Empty when… |
|---|---|---|
| `results` | The UC Data Classification scan engine: one row per detected sensitive class per column. | Classification **never enabled per catalog** (off by default); no serverless compute to run scans; scan hasn't completed (~24h); nothing sensitive detected; no `SELECT`. |

---

## Endpoints deep-dive — which table captures which endpoint type

This is the most common "endpoints exist but the table is empty" trap. Databricks has **several distinct
endpoint kinds**, and they do **not** all write to the same place:

| Endpoint type | Usage / traffic table | Cost table | Notes |
|---|---|---|---|
| **Custom model serving** | `serving.endpoint_usage` (+ `served_entities`) | `billing.usage` (`MODEL_SERVING`) | Only if AI Gateway **usage tracking** is on **and** the endpoint is **not route-optimized**. |
| **Foundation Model API — pay-per-token** | `serving.endpoint_usage` | `billing.usage` (`MODEL_SERVING`) | Usage tracking must be enabled. |
| **Foundation Model API — provisioned throughput** | `serving.endpoint_usage` | `billing.usage` (`MODEL_SERVING`) | Usage tracking must be enabled. |
| **External models** | `serving.endpoint_usage` | third-party bills the provider (not DBUs) | Usage tracking must be enabled. |
| **Feature / function serving** | *neither* serving table | `billing.usage` (`MODEL_SERVING`) | Not covered by usage tracking — cost only. |
| **Databricks agent endpoints** | *neither* — usage tracking **not supported** | `billing.usage` | Observe via inference/payload logging (a UC Delta table), not a system table. |
| **Vector Search (Mosaic AI)** | ❌ **NOT** `serving.endpoint_usage` | `billing.usage` (**`VECTOR_SEARCH`**) | Audited in `access.audit` (`service_name='vectorSearch'`). **This is why the serving tables look empty even when vector-search endpoints exist.** |
| **Anything via Unity AI Gateway (Beta)** | `ai_gateway.usage` | `billing.usage` | Separate table; needs the AI Gateway Beta explicitly enabled; **account-admin read only**. |

**Takeaways for "why is my serving/gateway table empty":**
- `serving.endpoint_usage` only covers **Model Serving** endpoints **with usage tracking enabled** — not
  vector search, not feature serving, not agents.
- `ai_gateway.usage` only has rows if the **Unity AI Gateway (Beta)** is turned on and traffic flows
  through it (and only an **account admin** can read it).
- **Vector search** activity is invisible to both — find it in `billing.usage` under
  `billing_origin_product = 'VECTOR_SEARCH'` (this library does that in `cost_vector_search_spend`).

---

## Step-by-step recipes — get data into a table

Each recipe is "do this → that table starts getting rows." Links point to the actual Databricks docs the
steps are drawn from. URLs are AWS (`/aws/en/`); Azure/GCP have equivalents under
`learn.microsoft.com/…/azure/databricks/` and `docs.databricks.com/gcp/en/`.

### 0. Enable a system schema — prerequisite for `access`, `query`, `serving`, `storage`, `lakeflow`, `ai_gateway`

1. As an **account/metastore admin**, list schema states and enable the one you need:
   ```bash
   databricks system-schemas list <metastore_id>
   databricks system-schemas enable <metastore_id> serving   # or access / query / storage / lakeflow / ai_gateway
   ```
2. Grant read access to non-admins (reads are privilege-scoped — no grant means **zero rows**, not an error):
   ```sql
   GRANT USE CATALOG ON CATALOG system TO `data-team`;
   GRANT USE SCHEMA  ON SCHEMA  system.serving TO `data-team`;
   GRANT SELECT      ON SCHEMA  system.serving TO `data-team`;
   ```
3. There is **no historical backfill** — collection starts only *after* enablement.

Docs: [System schemas — enable API](https://docs.databricks.com/api/workspace/systemschemas/enable) ·
[`system-schemas` CLI](https://docs.databricks.com/aws/en/dev-tools/cli/reference/system-schemas-commands) ·
[System tables (index)](https://docs.databricks.com/aws/en/admin/system-tables/)

### 1. Populate `system.serving.endpoint_usage` — Model Serving

1. Enable the **`serving`** system schema (recipe 0).
2. Have a **Model Serving endpoint** — a custom model, a Foundation Model API (pay-per-token *or* provisioned
   throughput), or an external model. *(Vector search, feature serving, and agent endpoints do **not** count.)*
3. Turn on **AI Gateway → Usage tracking** on that endpoint: Serving UI → open the endpoint → **Edit AI
   Gateway** → enable **Usage tracking** (or set `ai_gateway.usage_tracking_config` via the API/SDK).
   **Route-optimized** custom endpoints don't support usage tracking.
4. Send requests. Rows appear in `endpoint_usage`, with entity metadata in `served_entities` (join on
   `served_entity_id`).

Docs: [AI Gateway usage tracking](https://docs.databricks.com/aws/en/ai-gateway/usage-tracking-beta) ·
[Configure AI Gateway on endpoints](https://docs.databricks.com/aws/en/ai-gateway/configure-ai-gateway-endpoints) ·
[Manage serving endpoints](https://docs.databricks.com/aws/en/machine-learning/model-serving/manage-serving-endpoints)

### 2. Populate `system.ai_gateway.usage` — Unity AI Gateway (Beta)

1. An **account admin** enables the **Unity AI Gateway** Beta from the account console **Previews** page
   (Unity Catalog required; supported region only).
2. Enable the **`ai_gateway`** system schema (recipe 0).
3. Route traffic through a Unity AI Gateway model service (including `ai_query` to Databricks-provided models).
4. Query the table as an **account admin** (read is account-admin-only). If AI Gateway is never enabled the
   table stays empty and that traffic lands in `serving.endpoint_usage` instead.

Docs: [AI Gateway usage tracking (Beta)](https://docs.databricks.com/aws/en/ai-gateway/usage-tracking-beta) ·
[AI Gateway overview](https://docs.databricks.com/aws/en/ai-gateway/)

### 3. See Vector Search usage — it is NOT in the serving tables

1. Vector Search endpoints never write to `serving.endpoint_usage`. Find their **cost / DBUs** in
   `system.billing.usage` where `billing_origin_product = 'VECTOR_SEARCH'` (this library's
   `cost_vector_search_spend` does exactly this).
2. For an **audit** of vector-search actions, use `system.access.audit` where `service_name = 'vectorSearch'`.

Docs: [Vector Search cost management](https://docs.databricks.com/aws/en/vector-search/vector-search-cost-management) ·
[Model serving cost system table](https://docs.databricks.com/aws/en/admin/system-tables/model-serving-cost)

### 4. Populate `system.storage.*` — Predictive Optimization

1. Enable the **`storage`** system schema (recipe 0).
2. Ensure **Predictive Optimization** is on (ON by default for accounts created ≥ 2024-11-11; older accounts
   are in a rollout finishing ~Aug 2026) and your region supports it.
3. Have **UC managed tables** with real workload so PO decides to run OPTIMIZE / VACUUM / ANALYZE / clustering.
4. Rows appear in `predictive_optimization_operations_history` (up to ~2h lag; ~24h for the DBU cost field);
   `table_metrics_history` fills from the daily snapshot.

Docs: [Predictive optimization system table](https://docs.databricks.com/aws/en/admin/system-tables/predictive-optimization) ·
[Predictive optimization](https://docs.databricks.com/aws/en/optimizations/predictive-optimization)

### 5. Populate `system.data_classification.results`

1. Enable the **`data_classification`** system schema (recipe 0).
2. Ensure the workspace has **serverless compute** available (scans run on serverless).
3. Turn on **Data Classification per catalog**: Catalog Explorer → the catalog's **Details** tab → **Enable**
   (or the **Configure** button on the Data Classification results page). Needs `USE CATALOG` + `MANAGE` on the
   catalog; auto-tagging also needs `APPLY TAG` + `ASSIGN`.
4. Wait for the background scan (new objects scanned within ~24h). Detections show up as rows.

Docs: [Data classification system table](https://docs.databricks.com/aws/en/admin/system-tables/data-classification) ·
[Data classification](https://docs.databricks.com/aws/en/data-governance/unity-catalog/data-classification)

### 6. Capture fine-grained events in `system.access.audit`

1. Enable the **`access`** system schema (recipe 0).
2. Account-level events (logins, UC data access, jobs, warehouse start/stop…) are captured automatically. For
   **workspace-level detail** such as notebook/command runs, turn on **verbose audit logging** in the
   workspace admin settings.
3. Read as an admin (or grant `SELECT`); filter on `event_date` (not `event_time`), and remember account-level
   events carry `workspace_id = 0`.

Docs: [Audit log system table](https://docs.databricks.com/aws/en/admin/system-tables/audit-logs)

## Databricks documentation — per schema

- **Index:** [Monitor account activity with system tables](https://docs.databricks.com/aws/en/admin/system-tables/)
- **access:** [audit-logs](https://docs.databricks.com/aws/en/admin/system-tables/audit-logs) · [lineage](https://docs.databricks.com/aws/en/admin/system-tables/lineage) · [network](https://docs.databricks.com/aws/en/admin/system-tables/network) · [workspaces](https://docs.databricks.com/aws/en/admin/system-tables/workspaces)
- **ai_gateway / serving:** [usage tracking](https://docs.databricks.com/aws/en/ai-gateway/usage-tracking-beta) · [configure endpoints](https://docs.databricks.com/aws/en/ai-gateway/configure-ai-gateway-endpoints) · [serving overview](https://docs.databricks.com/aws/en/ai-gateway/overview-serving-endpoints) · [inference tables](https://docs.databricks.com/aws/en/ai-gateway/inference-tables)
- **billing:** [billing system tables](https://docs.databricks.com/aws/en/admin/system-tables/billing) · [usage](https://docs.databricks.com/aws/en/admin/usage/system-tables)
- **compute:** [compute](https://docs.databricks.com/aws/en/admin/system-tables/compute) · [warehouses](https://docs.databricks.com/aws/en/admin/system-tables/warehouses) · [warehouse-events](https://docs.databricks.com/aws/en/admin/system-tables/warehouse-events)
- **lakeflow:** [jobs](https://docs.databricks.com/aws/en/admin/system-tables/jobs) · [jobs cost](https://docs.databricks.com/aws/en/admin/system-tables/jobs-cost)
- **query:** [query-history](https://docs.databricks.com/aws/en/admin/system-tables/query-history)
- **storage:** [predictive-optimization](https://docs.databricks.com/aws/en/admin/system-tables/predictive-optimization) · [ANALYZE … COMPUTE STORAGE METRICS](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-syntax-aux-analyze-compute-storage-metrics)
- **information_schema:** [reference](https://docs.databricks.com/aws/en/sql/language-manual/sql-ref-information-schema) · [column_masks](https://docs.databricks.com/aws/en/sql/language-manual/information-schema/column_masks) · [filters & masks](https://docs.databricks.com/aws/en/data-governance/unity-catalog/filters-and-masks/)
- **data_classification:** [data-classification system table](https://docs.databricks.com/aws/en/admin/system-tables/data-classification)
- **endpoint types / vector search:** [Vector Search cost](https://docs.databricks.com/aws/en/vector-search/vector-search-cost-management) · [external models](https://docs.databricks.com/aws/en/generative-ai/external-models/)
