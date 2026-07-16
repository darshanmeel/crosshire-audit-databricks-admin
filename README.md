# CrossHire — Databricks System-Tables Query Library (admin)

A **copy-paste SQL library** for auditing a Databricks account's **cost, performance, compute, jobs, serving,
storage and governance** — built entirely on Databricks **system tables** (`system.*`). No app to install and
no dashboard: nearly every file is a plain `SELECT` you paste into a Databricks SQL editor / warehouse and
run — with **one documented exception**: `storage_breakdown_analyze` is an `ANALYZE TABLE` template (not a
SELECT), covered under [How to run](#how-to-run).

📖 **Full interactive docs → [learn.crosshire.ch/learn/tech/databricks/audit](https://learn.crosshire.ch/learn/tech/databricks/audit)**
Every query explained — why it matters, what it does in plain terms, how to read each output column, an
illustrative sample of the result, and the caveats.

🧰 **Sibling library → [crosshire-audit-snowflake-admin](https://github.com/darshanmeel/crosshire-audit-snowflake-admin)** —
the same idea for Snowflake: who can read an object (the transitive grant graph) via a live `SHOW GRANTS`
procedure, plus the `ACCOUNT_USAGE` CTE.

### Guides

- **▶ [First audit](https://learn.crosshire.ch/learn/tech/databricks/audit/first-audit) — start here.** A
  ~90-minute, priority-ranked walkthrough for a brand-new admin: run the ten ★ queries (no system-tables
  expertise needed) to validate the bill *first*, then see where the money goes, then surface the top
  security & governance risks — so you trust the numbers before you act on them.
- **[Investigation trails](https://learn.crosshire.ch/learn/tech/databricks/audit/trails).** Four decision-tree
  paths — cost overspend, job waste, governance risk, performance — that chain related queries along their
  `next:` links so you can trace a finding to its root cause instead of reading queries in isolation.
- **[Coverage & troubleshooting](https://learn.crosshire.ch/learn/tech/databricks/audit/coverage).** Which
  Unity Catalog grants unlock which queries, and how to read a missing-table / schema-access result as
  **`NOT_ASSESSED`** ("couldn't look") rather than mistaking it for a zero ("nothing there").

## 100 queries across 7 domains

| Domain | Queries | What it answers |
|---|--:|---|
| [Cost & Billing](queries/cost/) | 23 | Dollarized DBU spend by SKU / product / job / notebook / endpoint / tag / identity; list vs account price; egress; GenAI tokens |
| [Query Performance](queries/performance/) | 12 | Costly statements (raw + per-fingerprint), bytes scanned / pruning / spill / shuffle, cache cold-start, queuing, failed queries, workload mix |
| [Compute](queries/compute/) | 10 | Cluster & SQL-warehouse config, node utilization, idle ratio, autoscale churn, instance pools/events |
| [Jobs & Pipelines (Lakeflow)](queries/jobs_pipelines/) | 21 | Job/pipeline runs, failures, timeouts, retries, queue/cold-start, orphans, wasted DBUs, all-purpose placement |
| [Model Serving & AI](queries/serving_ai/) | 4 | Serving endpoint traffic, billing-anchored endpoint cost & usage-tracking status, AI-gateway token usage |
| [Storage & Optimization](queries/storage/) | 9 | Predictive Optimization (clustering / compaction / VACUUM), table inventory, time-travel, Iceberg, ANALYZE |
| [Governance, Access & Security](queries/governance_access/) | 21 | Grants, column masks / row filters, tags, data classification, lineage blast-radius, network denials, run-as escalation, admin changes; Delta Sharing exposure, volumes, views, PII outside governed tables |

> ⚠️ **Storage exception:** one of the Storage queries, `storage_breakdown_analyze`, is an `ANALYZE TABLE`
> template (**not** a `SELECT`) — `runnable: false`, so the read-only `run_audit.py` skips it. Sweep
> `ANALYZE … COMPUTE STORAGE METRICS` across tables with the **destructive, opt-in**
> [`tools/run_analyze.py`](tools/run_analyze.py) (dry-run by default; `--run --yes` to execute). See
> [How to run](#how-to-run).

Each domain folder's **`README.md`** is a one-line index of its queries; open the
**[interactive docs](https://learn.crosshire.ch/learn/tech/databricks/audit)** for the full write-up.

## What each query carries

Every `.sql` file opens with a structured header (see [`CONTRIBUTING.md`](CONTRIBUTING.md) for the
schema): what one row means (`read_this`), the healthy vs. investigate-if bands (labeled field
heuristics you tune with `:params`), a free / config / spend action ladder, and every methodological
caveat. **Finding** queries also emit a `status` column (`OK | WARN | CRITICAL | NOT_ASSESSED`) and
sort worst-first; **inventory** queries are stable references you join to.

[`queries/manifest.json`](queries/manifest.json) is a machine-readable index of all of the above,
**generated** from those headers by `python tools/build_manifest.py` (never hand-edited). The dbt-style
**lineage** — which `system.*` tables each query reads (sources → models) and which tables are joined
together — is likewise generated into [`lineage/`](lineage/) by `tools/build_lineage.py`; see the
[query-lineage section of `COVERAGE.md`](COVERAGE.md#query-lineage--which-queries-depend-on-each-table).

## How to run

1. Open a **Databricks SQL editor** (or a notebook on a SQL warehouse / Unity-Catalog-enabled cluster).
2. Ensure you have **`SELECT` on the `system.*`** schema the query reads — some schemas must be *enabled* by an
   account/metastore admin first.
3. Open a query, copy its SQL, set the look-back window on the `:period_days` parameter, and run.

**Or run the whole library at once** with [`tools/run_audit.py`](tools/run_audit.py) (Databricks SQL
connector) or its notebook twin [`tools/run_audit_notebook.py`](tools/run_audit_notebook.py): filter
by `--tier` / `--domain` / `--stars`, and it substitutes params, executes, records **NOT_ASSESSED**
for tables your account doesn't expose, and prints a scorecard. It is read-only unless you pass the
opt-in `--write-to catalog.schema`.

> ⚠️ **The one non-`SELECT` query.** `storage_breakdown_analyze` is an `ANALYZE TABLE … COMPUTE STORAGE
> METRICS` **template** (flagged `runnable: false`), so it is **excluded** from the read-only runner —
> copy it, substitute your own table, and run it by hand. To sweep `ANALYZE` across many tables at once,
> use the separate [`tools/run_analyze.py`](tools/run_analyze.py): it is a **destructive, opt-in maintenance**
> operation (not a plain SELECT, expensive at scale, DBR 18.0+), so it is **dry-run by default** — it lists
> the target tables and runs nothing until you pass `--run --yes`.

## What the tooling adds (beyond the SQL)

The `.sql` files answer the questions; the header + [`tools/`](tools/) layer turns them into something
you can **run, trust, and maintain** — without being a system-tables expert.

- **Run it, don't read it.** [`tools/run_audit.py`](tools/run_audit.py) (or the
  [notebook twin](tools/run_audit_notebook.py)) reads `manifest.json`, selects queries by `--tier` /
  `--domain` / `--stars`, substitutes your `:params`, executes each, and prints a scorecard — no opening
  100 files. The header's `read_this` / `healthy` / `investigate_if` / `actions` / `next` fields turn a
  table of numbers into a **finding with a fix and a next step**, so someone who doesn't know the schema
  can still act — and tune the thresholds to their account via `:params` instead of editing SQL.
- **Trust the result.** A query that *can't* be checked (table not enabled, no grant) is recorded
  **`NOT_ASSESSED`**, never a fake `0` — you never act on "nothing found" when the truth is "couldn't
  look." The runner is **read-only** unless you opt in with `--write-to`, and only validated numeric
  `:params` are ever inlined — safe to point at production.
- **Keep it correct over time.** [`tools/lint_headers.py`](tools/lint_headers.py) is the CI gate: every
  query must be fully documented, declare its thresholds, cross-link to real queries, avoid hard-coded
  windows, and emit only in-band `status` labels — and the generated `manifest.json` and `.sqlfluff`
  must stay in sync with the headers. A half-documented or drifted query can't merge, so the library
  stays trustworthy as it grows.

## Best-effort by design

Databricks system tables are **not uniformly available**: a query can return **nothing**, or fail with
`TABLE_OR_VIEW_NOT_FOUND` / `insufficient_privileges`, because a schema is Preview / not enabled, the feature
isn't used, Unity Catalog is required, or you lack `SELECT`. **None of that is a bug** — run what your account
supports, skip what it doesn't.

**→ [`COVERAGE.md`](COVERAGE.md)** documents, for **every** system table, exactly what populates it and why
it would be empty — including which serving / **vector-search** endpoint types feed which table (a common
"endpoints exist but the table is empty" trap), and how to enable a system schema.

## Conventions

- **Identities are partial-masked.** Every query that emits a user/principal identity (21 of them) masks it
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

## Owner & license

Owned and maintained by **[CrossHire](https://crosshire.ch)**. Licensed Apache-2.0 — see
[`LICENSE`](LICENSE); the header/verification conventions are documented in [`CONTRIBUTING.md`](CONTRIBUTING.md).
