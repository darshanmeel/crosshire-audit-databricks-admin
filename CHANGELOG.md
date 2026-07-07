# Changelog

All notable changes to this query library. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/); this project is not semver-versioned.

## [Unreleased] - v2 overhaul

### Added
- `LICENSE` (Apache-2.0) and a license note in the README.
- `CONTRIBUTING.md` — the v2 header schema, the plain-SELECT / money / caveat rules, and the
  `confirmed` vs `needs_confirmation` verification process (previously undocumented).
- `tools/header_schema.py`, `tools/build_manifest.py`, `tools/lint_headers.py` — the header is now
  the single source of truth; `queries/manifest.json` is **generated** from it, not hand-kept.
- **Header schema v2** on every query: `title`, `tier`, `reads`, `requires`, `params`,
  `confidence_note`, `read_this`, `healthy`, `investigate_if`, `actions`, `next`, plus
  user-facing `caveats`.
- **Interpretation layer** — `read_this` / `healthy` / `investigate_if` / `actions` / `next` on
  every finding query, authored first for the ten first-audit (★) picks.
- **`status` column** (`OK | WARN | CRITICAL | NOT_ASSESSED`) on finding queries, banded from the
  documented (parameter-driven) heuristics and ordered worst-first.
- `query_costly_statements_grouped.sql` — per-fingerprint rollup sibling of
  `query_costly_statements`.
- `est_wasted_usd_list` on `compute_idle_node_ratio` (directional: waste proportional to idle
  slices); `jobs_sharing_cluster` + `est_usd_list_share` and a NOT_ASSESSED bucket on
  `lakeflow_jobs_on_all_purpose`; `statement_fingerprint` on `query_costly_statements`.
- GitHub Actions CI running the header linter + manifest-sync check, plus an advisory sqlfluff
  parse job (`.sqlfluff` seeds the placeholder templater with every `:param` default).
- `tools/run_audit.py` + `tools/run_audit_notebook.py` — a manifest-driven runner (Databricks SQL
  connector) and its notebook twin: filter by `--tier`/`--domain`/`--stars`, substitute params,
  execute, record NOT_ASSESSED on missing/unreadable tables, print a scorecard. Writes only with
  the opt-in `--write-to catalog.schema` (Guardrail 4); read-only otherwise.

### Changed
- **One window parameter everywhere:** `:period_days` (default 30) replaces every hard-coded
  `INTERVAL 30/90 DAYS`, every `date_add(current_date(), -30)`, and the two `:lookback_days`
  usages. Retention-capped tables keep the cap in SQL via `LEAST(:period_days, 90)`.
- **Magic numbers promoted to `:params`** with defaults + rationale.
- **README masking note corrected:** identities/emails *are* partial-masked in-SQL (19 queries);
  no query emits a raw identity. Added tier definitions.
- Caveats rewritten to address the person running the query.

### Removed
- All internal-pipeline vocabulary from the public query files: the `feeds:` header, the
  `/* databricks_audit: */` markers, and every reference to the internal collector/verifier,
  the `--share` build, and internal file paths. (Verification methodology moved to
  `CONTRIBUTING.md`.)
