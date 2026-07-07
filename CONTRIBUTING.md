# Contributing

This repo is a **plain-SQL** library: 96 `SELECT` queries over Databricks `system.*` tables,
plus a small `tools/` folder that turns the query headers into `queries/manifest.json`.
Contributions are welcome — a new query, a sharper caveat, a better interpretation band.

## Hard rules (CI enforces these)

1. **Plain SELECT only.** No `CREATE` / `INSERT` / `UPDATE` / `DELETE` / `MERGE` / `SET` inside
   any file under `queries/`. A query reads system tables and returns rows — nothing else. (A
   runner that writes results to a table is opt-in and lives in `tools/`, never in `queries/`.)
2. **Money framing.** Every dollar column is an **estimate at list price** — name it
   `est_usd_list` (or `est_wasted_usd_list`, etc.) and say so in the header. `usage_quantity` /
   `net_dbus` are **DBUs, never dollars**. Never present a list-price estimate as the negotiated
   invoice rate (no system table carries that).
3. **Keep every methodological caveat.** You may *add* interpretation next to a caveat; you may
   never delete or soften one. "Empty ≠ zero", "not assessed", "before <date> this column was
   NULL" — that honesty layer is the product.
4. **Thresholds are labeled heuristics.** Any band you introduce is phrased as a *field
   heuristic — tune `:param` for your account*. Never "Databricks recommends" (fabricated
   authority) unless you are quoting a real, cited Databricks doc.
5. **Identities are partial-masked in-SQL.** If a query emits a user/principal, mask it (email
   `->` `da****@****`, service-principal GUID kept as-is, else first-2-chars + `****`). No raw
   identity leaves the workspace.
6. **ASCII only.** Use `->`, `-`, `>=`, straight quotes — no em-dashes, smart quotes, or arrows.
7. **One window param.** Every time-bounded query uses `:period_days` (default 30). No hard-coded
   `INTERVAL 30 DAYS`, no `date_add(current_date(), -30)`, and no `:lookback_days`. Where a system
   table has a hard retention limit (e.g. `system.compute.node_timeline` = 90 days), cap it *in
   SQL* — `LEAST(:period_days, 90)` — and say why in the header. A genuine point-in-time snapshot
   (a "current config" inventory with no time filter) has no window: it omits `:period_days` and
   its `params` line reads `none (config snapshot, no time window)`. The linter forbids hard-coded
   windows but does not force a window onto a windowless query.

## Header schema (v2)

Every `queries/<domain>/<query_id>.sql` opens with exactly these 14 comment fields, in order.
`tools/header_schema.py` parses them; `tools/build_manifest.py` turns them into the manifest.

```
-- query_id: <snake_case, identical to the filename>
-- title: <short human title>
-- domain: <cost|performance|compute|jobs_pipelines|serving_ai|storage|governance_access>   tier: <lite|standard|deep>
-- reads: <system.* tables, comma-separated>
-- requires: SELECT on <schemas>; <GA | must be enabled per-metastore | Public Preview | Unity Catalog required>
-- params: :period_days (default 30) rolling window in days; :threshold (default N) <what it does>; ...
-- confidence: confirmed | needs_confirmation
-- confidence_note: <one external-safe sentence; verification dates are fine>
-- read_this: <1-2 sentences: what ONE row means + the 1-2 columns that matter>
-- healthy: <band - field heuristic>                    (inventories: "n/a - inventory")
-- investigate_if: <band(s) - field heuristic>          (inventories: "n/a - inventory")
-- actions: 1) <free fix> 2) <config fix> 3) <spend-money fix>   (inventories: "n/a - inventory ...")
-- next: <query_id> (if <condition>), <query_id> (if <condition>)
-- caveats: <ALL methodological caveats, written to address the person running the query>
```

Field syntax the parser depends on:

- **domain line** must read `domain: <domain>   tier: <tier>` (both on one line).
- **params**: `;`-separated. Each is `:name (default <value>) <meaning>`. `:period_days` is mandatory.
- **next**: `,`-separated. Each is `query_id (if <condition>)` or bare `query_id`. No commas inside `(if ...)`. Every target must be a real query_id in this repo.
- **actions**: `1) ... 2) ... 3) ...`. Free fix first, spend-money fix last.
- **healthy / investigate_if / actions** on a **pure inventory** (a reference/lookup query with no
  health notion) are set to `n/a - inventory` rather than omitted, so the linter stays uniform.

## Finding queries vs inventories

- A **finding** query surfaces a problem (waste, risk, a broken config). It ends with an
  `... AS status` column banded `OK | WARN | CRITICAL | NOT_ASSESSED` from the documented
  heuristic (thresholds are `:params`), and it `ORDER BY`s worst-first. Rows the heuristic cannot
  judge (a NULL driver metric) are `NOT_ASSESSED`, never silently `OK`.
- An **inventory** query is a reference/lookup (price history, node-type catalog, grant listing).
  It has `read_this` + `next`, sets the band fields to `n/a - inventory`, and `ORDER BY`s a stable key.

## Verification: `confirmed` vs `needs_confirmation`

Each query declares a confidence level, and one `confidence_note` sentence explaining it.

- **confirmed** — every column and table the query reads was checked to exist and behave as the
  query assumes, against a live Unity-Catalog workspace, and the query returned sensible rows.
- **needs_confirmation** — the query is believed correct but something could not be fully verified
  on the reference workspace: a Preview table that was empty, a cross-domain join whose key
  population depends on account age, a decimal cast, or a multi-currency edge case. The
  `confidence_note` and `caveats` name the specific thing to confirm on *your* account.

When you change a query, re-verify its columns against `system.information_schema` /
`DESCRIBE`, and update the `confidence` + `confidence_note` accordingly. Downgrade to
`needs_confirmation` if you could not check something — do not leave a stale `confirmed`.

## Workflow

```
1. add/edit queries/<domain>/<query_id>.sql   (follow the schema above)
2. python tools/build_manifest.py             # regenerate queries/manifest.json from headers
3. python tools/lint_headers.py               # schema + hygiene + manifest-sync check
4. commit both the .sql and the regenerated manifest.json
```

`manifest.json` is **generated** — never hand-edit it. CI runs steps 2 (`--check`) and 3 on
every push.
