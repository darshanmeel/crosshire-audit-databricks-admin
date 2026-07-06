# CrossHire — Databricks System-Tables Query Library (admin)

A **copy-paste SQL library** for auditing a Databricks account's **cost, performance, compute,
jobs, serving, storage, and governance** — built entirely on Databricks **system tables**
(`system.*`). There is **no application to install and no dashboard here** — every file is a plain
`SELECT` you paste into a Databricks SQL editor / warehouse and run.

> 📖 **Guided tour (new):** [`docs/index.html`](docs/index.html) is a browsable, editorial explainer for the
> library — for each query it lays out *why it matters*, *what it does* step by step, *how to read every output
> column*, an *illustrative sample result*, and the *caveats*. Open it locally or via GitHub Pages (Settings →
> Pages → `/docs`). **Status:** format preview covering the first query (`cost_dollarized_by_sku_day`); the rest
> of the top 10 — then all 95 — follow in phases.

95 queries across **7 domains**:

| Domain | Queries | What it answers |
|---|--:|---|
| [Cost & Billing](queries/cost/) | 23 | Dollarized DBU spend by SKU / product / job / notebook / endpoint / tag / identity; list vs account price; egress; GenAI tokens |
| [Query Performance](queries/performance/) | 11 | Costly statements, bytes scanned / pruning / spill / shuffle, cache cold-start, queuing, failed queries, workload mix |
| [Compute](queries/compute/) | 10 | Cluster & SQL-warehouse config, node utilization, idle ratio, autoscale churn, instance pools/events |
| [Jobs & Pipelines (Lakeflow)](queries/jobs_pipelines/) | 21 | Job/pipeline runs, failures, timeouts, retries, queue/cold-start, orphans, wasted DBUs, all-purpose placement |
| [Model Serving & AI](queries/serving_ai/) | 4 | Serving endpoint traffic, dormant endpoints, AI-gateway token usage |
| [Storage & Optimization](queries/storage/) | 9 | Predictive Optimization (clustering / compaction / VACUUM), table inventory, time-travel, Iceberg, ANALYZE |
| [Governance, Access & Security](queries/governance_access/) | 17 | Grants, column masks / row filters, tags, data classification, lineage blast-radius, network denials, run-as escalation, admin changes |

Each domain folder has its own **`README.md`** documenting **every system table it uses** (grain,
key columns, availability) and **every query** (what it returns, why it matters).

---

## ⚠️ Disclaimer — some queries may not run (and that's expected)

Databricks system tables are **not uniformly available** on every account. A query here can
return **nothing**, or fail with `TABLE_OR_VIEW_NOT_FOUND` / `insufficient_privileges`, for any of
these reasons — none of which is a bug in the query:

- **Preview / not-yet-GA schemas** — several system schemas (e.g. `system.access`,
  `system.serving`, `system.data_classification`, `system.storage`, `system.lakeflow` sub-tables)
  are in Public Preview and may not exist on your metastore.
- **Must be enabled per-metastore** — some schemas are **off by default** and an account admin has
  to turn them on (schema-by-schema) before rows appear.
- **Edition / tier / feature gating** — a table only has data if you *use* that feature:
  no Model Serving → empty `system.serving.*`; no DLT/Lakeflow pipelines → empty pipeline tables;
  Predictive Optimization not enabled → empty `system.storage.predictive_optimization_*`;
  serverless-only metrics absent on classic-only accounts; `system.billing.cloud_infra_cost` and
  `account_prices` may require specific enablement.
- **Unity Catalog required** — `information_schema.*`, lineage, tags, masks, and most `access.*`
  tables exist only under Unity Catalog.
- **Permissions** — you need `SELECT` on the specific `system.*` schema/table (granted by an
  account/metastore admin). `system.access.audit` in particular is admin-gated.
- **Cloud / region differences** — SKU names, availability attributes, and egress records differ
  across AWS / Azure / GCP.
- **Feature simply unused in the window** — a valid table with zero matching rows returns an empty
  result, not an error.

**Treat every query as best-effort.** Run what your account supports; skip what it doesn't. Where a
table is known to be gated, the domain README calls it out under *Availability*.

---

## How to run

1. Open a **Databricks SQL editor** (or any notebook attached to a SQL warehouse / cluster with
   Unity Catalog).
2. Ensure you have **`SELECT` on `system.*`** (ask an account/metastore admin; some schemas must be
   *enabled* first — see the disclaimer).
3. Paste a query and run it. Most are self-contained single `SELECT`s.
4. **Date window:** queries over event/firehose tables (`billing.usage`, `query.history`,
   `*_run_timeline`, `node_timeline`, `access.audit`, `serving.endpoint_usage`) filter to a recent
   window — adjust the `INTERVAL … DAYS` / date predicate to your reporting period.

## Conventions
- Each `.sql` begins with a `-- query_id: <name>` comment matching its file name.
- Identities/emails are **not** masked by these raw queries (unlike the collector) — handle output
  as sensitive.
- Every dollar figure is **`est · at list`** (priced from `system.billing.list_prices`
  `effective_list` — pre-discount, DBU-only) unless the query explicitly joins `account_prices`.

## Publishing
This folder is self-contained and safe to publish as its own repo — it contains **only SQL and
documentation, no account data**. See per-domain READMEs for details.
