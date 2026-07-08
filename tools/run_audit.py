#!/usr/bin/env python3
"""Run the query library against a Databricks SQL warehouse, manifest-driven.

Reads queries/manifest.json, selects queries by tier/domain/stars, substitutes :params,
executes each over the Databricks SQL connector, and prints a scorecard. A query whose table
is missing or unreadable is recorded NOT_ASSESSED (with the reason) rather than failing the run
-- the "empty != zero / not assessed" honesty layer, applied at runtime.

    export DATABRICKS_SERVER_HOSTNAME=...    # adb-....azuredatabricks.net
    export DATABRICKS_HTTP_PATH=...          # /sql/1.0/warehouses/xxxx
    export DATABRICKS_TOKEN=...              # PAT or OAuth token

    python tools/run_audit.py --tier lite --stars                 # run the safe first-audit picks
    python tools/run_audit.py --domain cost,compute --period-days 60
    python tools/run_audit.py --stars --dry-run                    # print resolved SQL, no execution
    python tools/run_audit.py --tier lite --write-to main.audit    # OPT-IN: persist results (Guardrail 4)

Only --write-to writes anything; without it the run is strictly read-only. The write path lives
here in the runner, never inside the plain-SELECT query files.

Requires: pip install databricks-sql-connector  (only for actual execution, not --dry-run/--list).
Stdlib-only otherwise.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "queries"
MANIFEST = QUERIES / "manifest.json"

# Databricks error CLASSES that mean "the data isn't there to assess" (missing table / no grant /
# feature not enabled) — NOT a query bug. Matched as tokens against the bracketed error class the
# connector surfaces (e.g. "[TABLE_OR_VIEW_NOT_FOUND] ..."). Prose fragments like "does not exist"
# and bare "UnityCatalog" were REMOVED on purpose: they also appear in genuine bugs ("column X does
# not exist"), and the whole honesty layer breaks if a real failure is mislabeled "not assessed".
NOT_ASSESSED_SIGNS = [
    "TABLE_OR_VIEW_NOT_FOUND",
    "SCHEMA_NOT_FOUND",
    "CATALOG_NOT_FOUND",
    "INSUFFICIENT_PERMISSIONS",
    "INSUFFICIENT_PRIVILEGES",
    "PERMISSION_DENIED",
    "UC_NOT_ENABLED",
    "FEATURE_NOT_ENABLED",
]


def load_manifest() -> dict:
    return json.loads(MANIFEST.read_text(encoding="utf-8"))


def all_param_names(manifest: dict) -> set[str]:
    names = set()
    for entries in manifest.values():
        for e in entries:
            for p in e["params"]:
                names.add(p["name"])
    return names


def select(manifest: dict, tiers, domains, stars_only) -> list[dict]:
    out = []
    for domain, entries in manifest.items():
        if domains and domain not in domains:
            continue
        for e in entries:
            if tiers and e["tier"] not in tiers:
                continue
            if stars_only and not e["stars"]:
                continue
            out.append(e)
    return out


def resolve_sql(entry: dict, known: set[str], overrides: dict) -> str:
    """Substitute :param markers with validated numeric literals (all params are numeric)."""
    sql = (QUERIES / entry["domain"] / f"{entry['query_id']}.sql").read_text(encoding="utf-8")
    # strip the leading comment header (keep only the statement)
    body = "\n".join(l for l in sql.splitlines() if not l.startswith("--"))
    values = {p["name"]: p["default"] for p in entry["params"]}
    values.update({k: v for k, v in overrides.items() if k in known})

    def repl(m):
        name = m.group(1)
        if name not in values:
            raise KeyError(f"{entry['query_id']}: no value for :{name}")
        v = values[name]
        float(v)  # guard: numeric only -> safe to inline, no injection surface
        return str(v)

    # only substitute KNOWN param names, so ':00' inside a time literal is never touched
    pattern = r":(" + "|".join(sorted(known, key=len, reverse=True)) + r")\b"
    return re.sub(pattern, repl, body).strip().rstrip(";")


def classify_error(msg: str) -> str:
    m = (msg or "").upper()
    if "STATEMENT_TIMEOUT" in m or "TIMED OUT" in m or "QUERY TIMEOUT" in m:
        return "TIMEOUT"
    return "NOT_ASSESSED" if any(s.upper() in m for s in NOT_ASSESSED_SIGNS) else "ERROR"


_WRITE_TO_RE = re.compile(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$")


def status_summary(cols, rows) -> str:
    if "status" not in cols:
        return ""
    i = cols.index("status")
    counts = {}
    for r in rows:
        counts[r[i]] = counts.get(r[i], 0) + 1
    order = ["CRITICAL", "WARN", "OK", "NOT_ASSESSED"]
    return " ".join(f"{k}={counts[k]}" for k in order if k in counts)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--tier", help="comma list: lite,standard,deep")
    ap.add_argument("--domain", help="comma list of domains")
    ap.add_argument("--stars", action="store_true", help="only the first-audit (star) picks")
    ap.add_argument("--period-days", type=int, help="override :period_days for every query")
    ap.add_argument("--param", action="append", default=[], metavar="name=value",
                    help="override a threshold param (repeatable)")
    ap.add_argument("--write-to", metavar="catalog.schema",
                    help="OPT-IN: persist each result to <catalog.schema>.<query_id> (Guardrail 4)")
    ap.add_argument("--timeout", type=int, default=300,
                    help="per-query statement timeout in seconds (default 300); a query that exceeds it "
                         "is recorded TIMEOUT and the run continues")
    ap.add_argument("--dry-run", action="store_true", help="print resolved SQL, do not execute")
    ap.add_argument("--list", action="store_true", help="list selected queries and exit")
    args = ap.parse_args()

    # H1: --write-to is interpolated into DDL, so it must be a plain catalog.schema identifier.
    # Reject anything else BEFORE connecting (no injection / no broken DDL from spaces or hyphens).
    if args.write_to and not _WRITE_TO_RE.match(args.write_to):
        print(f"--write-to must be 'catalog.schema' (letters, digits, underscore only), "
              f"got {args.write_to!r}", file=sys.stderr)
        return 2

    manifest = load_manifest()
    known = all_param_names(manifest)
    tiers = set(args.tier.split(",")) if args.tier else set()
    domains = set(args.domain.split(",")) if args.domain else set()
    overrides = {}
    if args.period_days is not None:
        overrides["period_days"] = args.period_days
    for kv in args.param:
        k, _, v = kv.partition("=")
        try:
            overrides[k.strip()] = float(v) if ("." in v or "e" in v.lower()) else int(v)
        except ValueError:
            print(f"--param {k.strip()}={v!r} must be a number", file=sys.stderr)
            return 2

    selected_all = select(manifest, tiers, domains, args.stars)
    if not selected_all:
        print("no queries matched the selection.", file=sys.stderr)
        return 1

    if args.list:
        for e in selected_all:
            star = "*" if e["stars"] else " "
            tag = "" if e.get("runnable", True) else "  [copy-paste only - not run]"
            print(f"{star} [{e['tier']:8}] {e['domain']:18} {e['query_id']}{tag}")
        print(f"\n{len(selected_all)} queries selected.")
        return 0

    # Copy-paste-only queries (runnable: false, e.g. the ANALYZE TABLE storage template) are never
    # executed by this READ-ONLY SELECT runner. Run them by hand, or use tools/run_analyze.py.
    manual = [e for e in selected_all if not e.get("runnable", True)]
    selected = [e for e in selected_all if e.get("runnable", True)]
    if manual:
        print(f"note: excluding {len(manual)} copy-paste-only quer"
              f"{'y' if len(manual) == 1 else 'ies'} (not a plain SELECT): "
              f"{', '.join(e['query_id'] for e in manual)}", file=sys.stderr)

    if args.dry_run:
        for e in selected:
            print(f"\n-- ===== {e['query_id']} ({e['tier']}) =====")
            print(resolve_sql(e, known, overrides))
        return 0

    # Real execution needs the connector.
    try:
        from databricks import sql as dbsql
    except ImportError:
        print("databricks-sql-connector not installed. `pip install databricks-sql-connector`,\n"
              "or use --dry-run / --list.", file=sys.stderr)
        return 2

    host = os.environ.get("DATABRICKS_SERVER_HOSTNAME")
    http_path = os.environ.get("DATABRICKS_HTTP_PATH")
    token = os.environ.get("DATABRICKS_TOKEN")
    if not all([host, http_path, token]):
        print("set DATABRICKS_SERVER_HOSTNAME, DATABRICKS_HTTP_PATH, DATABRICKS_TOKEN.", file=sys.stderr)
        return 2

    scorecard = []
    with dbsql.connect(server_hostname=host, http_path=http_path, access_token=token) as conn:
        # M5: bound every statement so one pathological query can't hang the whole audit.
        with conn.cursor() as _c:
            _c.execute(f"SET STATEMENT_TIMEOUT = {int(args.timeout)}")
        for e in selected:
            qid = e["query_id"]
            sql = resolve_sql(e, known, overrides)
            t0 = time.time()
            try:
                with conn.cursor() as cur:
                    if args.write_to:
                        cat, sch = args.write_to.split(".")
                        target = f"`{cat}`.`{sch}`.`{qid}`"  # backtick-quoted identifier (H1)
                        cur.execute(f"CREATE OR REPLACE TABLE {target} AS {sql}")
                        cur.execute(f"SELECT * FROM {target}")
                    else:
                        cur.execute(sql)
                    cols = [c[0] for c in cur.description] if cur.description else []
                    rows = cur.fetchall()
                dt = time.time() - t0
                extra = status_summary(cols, rows)
                if not rows:  # empty result -> point at the coverage reasons it COULD be empty (empty_if)
                    cov = ", ".join(e.get("empty_if", []))
                    extra = f"0 rows - maybe: {cov}" if cov else "0 rows"
                scorecard.append((qid, e["tier"], "OK", len(rows), extra, f"{dt:.1f}s"))
            except Exception as ex:  # noqa: BLE001 - runtime resilience is the point
                outcome = classify_error(str(ex))
                reason = str(ex).splitlines()[0]  # L5: truncated once, at print, below
                if outcome == "NOT_ASSESSED":  # attribute the miss to the query's declared coverage gaps
                    cov = ", ".join(e.get("empty_if", []))
                    if cov:
                        reason = f"{reason} | maybe: {cov}"
                scorecard.append((qid, e["tier"], outcome, 0, reason, f"{time.time()-t0:.1f}s"))

    # Scorecard. `status / reason` is truncated in exactly ONE place (the {:60.60} field).
    print(f"\n{'query_id':40} {'tier':8} {'outcome':12} {'rows':>6} {'status / reason':60} time")
    print("-" * 146)
    counts = {}
    for qid, tier, outcome, nrows, extra, dt in scorecard:
        counts[outcome] = counts.get(outcome, 0) + 1
        print(f"{qid:40} {tier:8} {outcome:12} {nrows:>6} {extra:60.60} {dt}")
    print("-" * 146)
    print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if args.write_to:
        print(f"\nresults persisted under {args.write_to}.<query_id>")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
