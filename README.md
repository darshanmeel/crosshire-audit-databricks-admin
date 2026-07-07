# CrossHire — Databricks System-Tables Query Library (admin)

A **copy-paste SQL library** for auditing a Databricks account's **cost, performance, compute, jobs, serving,
storage and governance** — built entirely on Databricks **system tables** (`system.*`). No app to install and
no dashboard: every file is a plain `SELECT` you paste into a Databricks SQL editor / warehouse and run.

📖 **Full interactive docs → [learn.crosshire.ch/learn/tech/databricks/audit](https://learn.crosshire.ch/learn/tech/databricks/audit)**
Every query explained — why it matters, what it does in plain terms, how to read each output column, an
illustrative sample of the result, and the caveats.

## 95 queries across 7 domains

| Domain | Queries | What it answers |
|---|--:|---|
| [Cost & Billing](queries/cost/) | 23 | Dollarized DBU spend by SKU / product / job / notebook / endpoint / tag / identity; list vs account price; egress; GenAI tokens |
| [Query Performance](queries/performance/) | 11 | Costly statements, bytes scanned / pruning / spill / shuffle, cache cold-start, queuing, failed queries, workload mix |
| [Compute](queries/compute/) | 10 | Cluster & SQL-warehouse config, node utilization, idle ratio, autoscale churn, instance pools/events |
| [Jobs & Pipelines (Lakeflow)](queries/jobs_pipelines/) | 21 | Job/pipeline runs, failures, timeouts, retries, queue/cold-start, orphans, wasted DBUs, all-purpose placement |
| [Model Serving & AI](queries/serving_ai/) | 4 | Serving endpoint traffic, dormant endpoints, AI-gateway token usage |
| [Storage & Optimization](queries/storage/) | 9 | Predictive Optimization (clustering / compaction / VACUUM), table inventory, time-travel, Iceberg, ANALYZE |
| [Governance, Access & Security](queries/governance_access/) | 17 | Grants, column masks / row filters, tags, data classification, lineage blast-radius, network denials, run-as escalation, admin changes |

Each domain folder's **`README.md`** is a one-line index of its queries; open the
**[interactive docs](https://learn.crosshire.ch/learn/tech/databricks/audit)** for the full write-up.

## How to run

1. Open a **Databricks SQL editor** (or a notebook on a SQL warehouse / Unity-Catalog-enabled cluster).
2. Ensure you have **`SELECT` on the `system.*`** schema the query reads — some schemas must be *enabled* by an
   account/metastore admin first.
3. Open a query, copy its SQL, set the look-back window on the `:period_days` parameter, and run.

## Best-effort by design

Databricks system tables are **not uniformly available**: a query can return **nothing**, or fail with
`TABLE_OR_VIEW_NOT_FOUND` / `insufficient_privileges`, because a schema is Preview / not enabled, the feature
isn't used, Unity Catalog is required, or you lack `SELECT`. **None of that is a bug** — run what your account
supports, skip what it doesn't.

## Conventions

- **Identities are partial-masked.** Every query that emits a user/principal identity (19 of them) masks it
  in-SQL — an email becomes `da****@****`, a service-principal GUID is kept as-is (already opaque), anything
  else becomes first-two-chars + `****`. No query emits a raw username or email. Output is still
  **sensitive** (workspace IDs, job IDs, table names, spend) — treat result CSVs as confidential and never
  commit them (`.gitignore` blocks `*.csv`).
- Every dollar figure is **`est · at list`** (from `system.billing.list_prices` `pricing.default` /
  `effective_list` — pre-discount, DBU-only). It is a directional list-price estimate, **not** your
  negotiated invoice rate (no system table carries that), and `usage_quantity` / `net_dbus` columns are
  **DBUs, never dollars**.

## Tiers

Each query carries a `tier` in its header and in [`manifest.json`](queries/manifest.json):

- **lite** — safe, always-available system tables (mostly `system.billing.*`, `system.compute.*`); run these first.
- **standard** — needs a cross-domain join or a schema that a metastore admin may have to enable.
- **deep** — needs Preview / Unity-Catalog-only schemas (lineage, classification, storage internals) that many accounts don't expose; expect some to return nothing or `TABLE_OR_VIEW_NOT_FOUND`.

## License

Apache-2.0 — see [`LICENSE`](LICENSE). Contributions and the header/verification conventions are documented in [`CONTRIBUTING.md`](CONTRIBUTING.md).
