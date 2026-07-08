# Dashboard Plan — CrossHire Databricks Audit (Lakeview, DAB-deployable)

> **Status: PLAN ONLY. No code in this document.** This is the design spec for a native
> Databricks AI/BI (Lakeview) dashboard, packaged as a Databricks Asset Bundle (DAB) and
> deployed from a local machine, that surfaces this repository's **100 queries**. It closes
> FinOps acceptance gap **#13 (DABs-deployable)**.

---

## 1. Goals & non-goals

**Goals**
- One **native Databricks dashboard** (`.lvdash.json`) that presents the library's 100 queries,
  organised into a small number of pages — **mainly aggregate** headline panels up top, finding
  tables (worst-first by `status`) below.
- **Deployable from a laptop** with `databricks bundle deploy` — no manual dashboard clicking.
- **Per-panel tooltips**: what the panel is, and what data could be missing / why it may be empty.
- A **Coverage & Gaps** tab: which `system.*` tables are populated, empty, or not collected/enabled.
- A **How to read** tab: the legend and per-page reading guidance.
- **Filters**: time window, environment (dev/uat/prd heuristic from workspace name), warehouse, user.

**Non-goals (explicitly out of scope for this plan)**
- No budget / forecast / variance / owner "companion" tables. (Those are FinOps org-intent tables
  Databricks has no system table for — see [§13 Known limits](#13-known-measurement-limits-finops).)
- No materialised/derived data. Every panel reads `system.*` **live** at view time.
- No re-writing of the 100 queries. They are reused **as-is** (see [§6](#6-datasets)).

## 2. Design decisions (locked)

| Decision | Choice |
|---|---|
| **Source of panels** | This repo's **100 queries** (`queries/**/*.sql`), reused **as-is**. |
| **Architecture style** | Aggregated + tabbed (headline KPIs → domain finding tables → coverage/how-to), our own naming — nothing borrowed from any other dashboard. |
| **Datasets** | One Lakeview dataset **per query**, verbatim, driven by its existing `:params`. |
| **Gaps tab** | **Data-coverage** view: per `system.*` table — populated / empty / not-collected / not-enabled. Not a budget/owner tracker. |
| **Home repo** | `crosshire-audit-databricks-admin` (this repo), generated from its `queries/manifest.json`. |
| **Data policy** | Reads `system.*` live; nothing materialised or committed. Public-repo-safe. |

## 3. Deliverable — DAB bundle layout

A new top-level `dashboard/` folder (built in a later step; **this doc creates none of it**):

```
dashboard/
  databricks.yml              # bundle: name, targets (dev/prd), vars (warehouse_id, parent_path)
  resources/
    dashboard.yml             # resources.dashboards.<name> -> src/crosshire_audit.lvdash.json
  src/
    crosshire_audit.lvdash.json   # GENERATED: pages, datasets, widgets, filters
    datasets/                     # GENERATED: one <query_id>.sql per panel (verbatim query body)
  README.md                   # how to deploy
tools/
  build_dashboard.py          # GENERATES src/ from queries/manifest.json + dashboard/layout.yml
  dashboard/layout.yml        # HUMAN-curated: which query -> which page / viz / filter bindings
```

The dashboard resource in `resources/dashboard.yml` is a standard DAB `dashboards` resource:
a `display_name`, the `file_path` to the `.lvdash.json`, a `warehouse_id` (bundle variable), and a
`parent_path` (workspace folder). `databricks bundle deploy` publishes it.

## 4. Pages (tabs)

Nine pages. Domain pages mirror the repo's seven domains 1:1, plus two cross-cutting tabs.

| # | Page | Purpose | Aggregate panels (top) | Finding/detail tables (below) |
|--:|---|---|---|---|
| 1 | **Overview** | One-screen account health | est $/mo, DBUs, prod-spend %, # workspaces; spend-by-env; 90-day spend trend; **findings-by-status** rollup | Top-10 cost drivers |
| 2 | **Cost & Allocation** | Where the money goes; how much is attributed | spend by SKU / product / env / workspace; **allocation-coverage %**; **unclassified %**; egress; GenAI tokens | chargeback by tag / identity |
| 3 | **Compute & Performance** | Utilisation, waste, slow queries | idle-node %; autoscale churn; warehouse idle; bytes-scanned / pruning / spill; queue waits | costly statements (top-N); cluster/warehouse config |
| 4 | **Jobs & Pipelines** | Reliability & job waste | failure-rate trend; wasted DBUs; timeout/retry counts; all-purpose placement | failed / zombie / orphan-owner job tables |
| 5 | **Serving & AI** | Endpoint cost & idleness | endpoint cost + **tracking-status** split; gateway tokens / latency | endpoint cost + tracking table |
| 6 | **Storage & Optimization** | Predictive Optimization & table health | PO ops by type; reclaimed bytes; table-metrics trend | dead-table candidates |
| 7 | **Governance & Access** | Who can touch what; where PII leaks guardrails | classification coverage; mask/filter counts; **PII-outside-tables**; Delta-Sharing exposure; network denials | grants; run-as escalation; orphan owners |
| 8 | **Coverage & Gaps** | Which data is actually there | per-table coverage matrix (populated / empty / not collected / not enabled) | list of empty panels + the `empty_if` reason each |
| 9 | **How to read** | Legend & reading guide | status legend; filter/param guide; per-page notes | known measurement limits |

## 5. Query → page mapping

All 100 queries appear (as a panel and/or a linked detail table). Distribution matches the repo:

| Page | Domain folder | # queries |
|---|---|--:|
| Cost & Allocation | `queries/cost/` | 23 |
| Compute & Performance | `queries/compute/` + `queries/performance/` | 10 + 12 |
| Jobs & Pipelines | `queries/jobs_pipelines/` | 21 |
| Serving & AI | `queries/serving_ai/` | 4 |
| Storage & Optimization | `queries/storage/` | 9 |
| Governance & Access | `queries/governance_access/` | 21 |
| Overview | (aggregate re-use of cost + status rollup) | — |
| **Total distinct queries** | | **100** |

Within each page, `layout.yml` assigns every query one of four roles:
- **KPI** — single headline number (tile).
- **Chart** — a time series or breakdown (bar/line/area).
- **Table** — a worst-first finding table (has a `status` column) or an inventory reference.
- **Linked** — deep/inventory queries not drawn as a chart; reachable from a "detail" table link.

`layout.yml` is the only hand-authored artifact; everything else is generated from it + the manifest.

## 6. Datasets

- **One Lakeview dataset per query**, the **query body copied verbatim** from `queries/**/*.sql`.
- Parameters stay exactly as the query declares them (`:period_days`, `:top_n`, `:warn_*`, …). The
  runner already proves these resolve; the dashboard binds them to widgets (see [§7](#7-filters)).
- `build_dashboard.py` reads `queries/manifest.json` for each query's `params`, `reads`, `read_this`,
  `empty_if`, and `caveats`, and emits the dataset SQL + the widget + the tooltip in one pass.
- Because queries are reused as-is, a global filter only affects a panel **when that query already
  emits the filtered column** (documented per filter in [§7](#7-filters)). No query is modified to
  add a dimension.

## 7. Filters

Four dashboard-level controls. Each is a native Lakeview filter/parameter; each applies to the
**subset of panels whose query exposes the relevant column** (the honest consequence of "reuse as-is").

| Filter | Control | Bound to | Applies to |
|---|---|---|---|
| **Time window** | integer parameter `:period_days` (default 30) | the `:period_days` param every windowed query already declares | all time-windowed queries; current-state/inventory queries have no window and are unaffected |
| **Environment** | single/multi-select `prod \| uat \| dev \| unknown` | a small **env-classifier helper dataset** (see below), cross-filtered on `workspace_id` | panels whose query emits `workspace_id` (cost, performance, compute, jobs, serving, `access.audit` governance) |
| **Warehouse** | multi-select | `warehouse_id` / warehouse name | performance (`query.history`), compute (warehouse events/config), DBSQL cost |
| **User** | **dynamic** multi-select, populated from the data's masked identities (`da****`) — no hardcoded list | the masked identity column | the 21 identity-masking queries |

**Env classifier — the one piece of shared logic.** So the 100 queries stay untouched, the env
filter is powered by a single helper dataset that classifies each workspace, and cross-filters any
panel that shares `workspace_id`:

```
workspace_id, workspace_name, env
  env = CASE
    WHEN lower(workspace_name) RLIKE '(^|[^a-z])(uat|test|qa|stag|sandbox|sit|nonprod|preprod)([^a-z]|$)' THEN 'uat'
    WHEN lower(workspace_name) RLIKE '(^|[^a-z])(dev|devel|develop)([^a-z]|$)'                           THEN 'dev'
    WHEN lower(workspace_name) RLIKE '(^|[^a-z])(prod|prd|production|live)([^a-z]|$)'                     THEN 'prod'
    ELSE 'unknown' END
```
(uat is tested before dev before prod; word-boundary matched.) Source: `system.access.workspaces_latest`.

> A true start/end **date range** (rather than a trailing `:period_days`) would need two new
> params (`:start_date` / `:end_date`) added to the windowed queries — offered as an optional
> extension, not assumed here, since it would touch the query bodies.

## 8. Panel tooltips (generated, not hand-written)

Every panel carries an info tooltip assembled by `build_dashboard.py` from `manifest.json`:

1. **What it is** — the query's `read_this`.
2. **Could be empty / missing if…** — its `empty_if` tokens expanded to plain English
   (e.g. `usage_tracking_off` → "the serving endpoint has AI-Gateway usage tracking off"),
   plus the relevant `caveats` line.
3. **Source** — the `query_id`, traceable to the exact `.sql` file.

This keeps the dashboard's explanatory text in lockstep with the query headers — the same
"generated from headers, gate-enforced" rule the rest of the repo already follows.

## 9. Coverage & Gaps tab

The data-coverage view (the point you asked for: *which table shows 0 and which isn't collected*).
Two panels, both derived from what the library already knows:

**(a) Per-table coverage matrix** — one row per `system.*` table the library reads (the 47 sources
already in `lineage/sources.yml`), each classified live:

| State | Meaning | How it's detected |
|---|---|---|
| **Populated** | rows present in the window | `COUNT(*) > 0` on a light probe |
| **Empty (no activity)** | table exists but no matching rows | `COUNT(*) = 0`, table readable |
| **Not collected** | schema/table not enabled or in Preview | probe raises `TABLE_OR_VIEW_NOT_FOUND` / schema disabled |
| **No access** | privilege-scoped away | probe raises `insufficient_privileges` |

Each row links to its COVERAGE.md explanation and lists the `empty_if` reason(s). This is a live
rendering of `COVERAGE.md` + the `empty_if` field + the runner's `NOT_ASSESSED` logic.

**(b) Empty panels this session** — a list of every dashboard panel currently returning 0 rows,
with the `empty_if`-derived reason, so an empty chart is read as *"couldn't look / nothing yet"*
rather than a true zero.

## 10. How to read tab

Static, generated from the headers + `COVERAGE.md`:
- **Status legend** — `OK` / `WARN` / `CRITICAL` / `NOT_ASSESSED`, and that finding tables sort worst-first.
- **Money legend** — every `$` is `est · at list` (list price, pre-discount, DBU-only), and
  `usage_quantity` / `net_dbus` are **DBUs, not dollars**.
- **Identity legend** — identities are partial-masked (`da****@****`); the user filter operates on masked values.
- **Filters & params** — what `:period_days`, env, warehouse, and user each do, and which panels they affect.
- **Per-page notes** — one line per page on how to read its main chart.
- **Known limits** — link to [§13](#13-known-measurement-limits-finops).

## 11. DAB bundle & deploy flow

`databricks.yml` defines the bundle name, two **targets** (`dev`, `prd`) selecting the workspace +
warehouse via variables, and includes `resources/dashboard.yml`. Deploy from a laptop:

```
cd dashboard
databricks bundle validate
databricks bundle deploy -t dev      # publishes the dashboard to the target workspace
# open the published dashboard in the workspace UI
```

Bundle **targets** (`dev`/`prd`) are a *deployment* concept (which workspace to publish to) and are
**separate** from the in-dashboard **environment filter** (which classifies each row's workspace).

## 12. Generation pipeline

Consistent with `build_manifest.py` / `build_sqlfluff_params.py` / `build_lineage.py`:

1. `dashboard/layout.yml` (hand-authored) maps each `query_id` → page, role (KPI/chart/table/linked),
   viz type, and filter bindings.
2. `tools/build_dashboard.py` reads `layout.yml` + `queries/manifest.json` + the `.sql` bodies and
   emits `dashboard/src/datasets/*.sql` + `dashboard/src/crosshire_audit.lvdash.json` (with tooltips).
3. `tools/lint_headers.py --check` gains a `--check` for the dashboard, so it can't drift: every
   query must appear in `layout.yml`, every dataset must match its `.sql` body, and every panel
   tooltip must match the current `read_this` / `empty_if`.

## 13. Known measurement limits (FinOps)

The dashboard shows everything the library can measure, but the following FinOps acceptance criteria
**cannot** be satisfied by SQL over `system.*` and are therefore surfaced as limits (not panels):
budget, variance-vs-budget, and forecast do not exist in any system table; alert-response SLAs,
measure-implementation registers, ownership registries, and monthly-review governance are
organisational processes. These are documented in the **How to read** tab so an operator does not
mistake their absence for a dashboard defect. (Full breakdown: the 13-criteria analysis already
delivered in chat.)

## 14. Phasing

| Phase | Scope | Closes |
|---|---|---|
| **P1** | Bundle skeleton + Overview + Cost pages + `:period_days` & env filters + generated tooltips | #13 (DABs) |
| **P2** | Remaining domain pages (Compute/Perf, Jobs, Serving, Storage, Governance) + warehouse & user filters | — |
| **P3** | Coverage & Gaps tab + How to read tab + the `--check` gate for the dashboard | — |

## 15. Open decisions (before build)

1. **Warehouse for the dashboard datasets** — which SQL warehouse ID the bundle deploys against
   (a bundle variable; one per target).
2. **Workspace folder (`parent_path`)** — where the published dashboard lands in each workspace.
3. **Date range vs window** — keep the trailing `:period_days` (no query changes), or add
   `:start_date` / `:end_date` for a true range (touches query bodies).
4. **Page count** — seven domain pages as above, or fold Compute+Performance and
   Storage into fewer pages if the tab bar feels heavy.
