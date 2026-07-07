#!/usr/bin/env python3
"""Sweep ANALYZE TABLE ... COMPUTE STORAGE METRICS across many tables  (DESTRUCTIVE / opt-in).

!!! CAUTION -- this is NOT a read-only audit. !!!
It runs `ANALYZE TABLE <t> COMPUTE STORAGE METRICS` -- a maintenance DDL statement -- against EVERY
table matched by the scope filters. At account scale that is EXPENSIVE (it scans each table's storage)
and it is not a plain SELECT. It needs DBR 18.0+ and privilege to ANALYZE each target table. This is
the automated, guarded companion to queries/storage/storage_breakdown_analyze.sql (which is a
copy-paste-only template, excluded from the read-only tools/run_audit.py).

It is DRY-RUN by default: it only LISTS the tables it would analyze. Nothing runs until you pass
BOTH --run and --yes.

    # same env as run_audit.py:
    export DATABRICKS_SERVER_HOSTNAME=...   DATABRICKS_HTTP_PATH=...   DATABRICKS_TOKEN=...

    python tools/run_analyze.py                                   # DRY-RUN: list target tables, run nothing
    python tools/run_analyze.py --catalog main --schema sales     # scope it down (recommended)
    python tools/run_analyze.py --like '%orders%' --limit 50      # only matching names, capped
    python tools/run_analyze.py --catalog main --run --yes        # ACTUALLY analyze the scoped tables

Requires: pip install databricks-sql-connector. Stdlib otherwise.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_audit import classify_error  # noqa: E402  reuse the OK/NOT_ASSESSED/ERROR/TIMEOUT classifier

_IDENT_RE = re.compile(r"^[A-Za-z0-9_]+$")

CAUTION = r"""
============================================================================
  !!   run_analyze is DESTRUCTIVE -- NOT a read-only audit   !!
============================================================================
  Runs  ANALYZE TABLE <t> COMPUTE STORAGE METRICS  (a maintenance DDL
  statement) against EVERY table listed below. At scale this is EXPENSIVE --
  it scans each table's storage -- and it is not a plain SELECT. Requires
  DBR 18.0+ and privilege to ANALYZE each target. Scope it down (--catalog /
  --schema / --like / --limit) before you --run.
============================================================================
"""


def list_tables(cur, catalog, schema, like, limit):
    """Return [(catalog, schema, name)] for real (non-view) tables matching the scope."""
    where = ["table_type IN ('MANAGED', 'EXTERNAL')"]
    if catalog:
        where.append(f"table_catalog = '{catalog}'")
    if schema:
        where.append(f"table_schema = '{schema}'")
    if like:
        where.append("table_name LIKE '" + like.replace("'", "''") + "'")
    sql = ("SELECT table_catalog, table_schema, table_name "
           "FROM system.information_schema.tables WHERE " + " AND ".join(where) +
           " ORDER BY table_catalog, table_schema, table_name")
    if limit:
        sql += f" LIMIT {int(limit)}"
    cur.execute(sql)
    return [(r[0], r[1], r[2]) for r in cur.fetchall()]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--catalog", help="restrict to one catalog (identifier)")
    ap.add_argument("--schema", help="restrict to one schema (identifier)")
    ap.add_argument("--like", help="only tables whose name matches this SQL LIKE pattern (e.g. '%%orders%%')")
    ap.add_argument("--limit", type=int, help="cap the number of tables analyzed")
    ap.add_argument("--run", action="store_true", help="ACTUALLY run ANALYZE (default is dry-run: list only)")
    ap.add_argument("--yes", action="store_true", help="required with --run: confirm you accept this is destructive")
    ap.add_argument("--timeout", type=int, default=600, help="per-table statement timeout in seconds (default 600)")
    args = ap.parse_args()

    for flag, val in (("--catalog", args.catalog), ("--schema", args.schema)):
        if val and not _IDENT_RE.match(val):
            print(f"{flag} must be a plain identifier (letters/digits/underscore), got {val!r}", file=sys.stderr)
            return 2

    try:
        from databricks import sql as dbsql
    except ImportError:
        print("databricks-sql-connector not installed. `pip install databricks-sql-connector`.", file=sys.stderr)
        return 2

    host = os.environ.get("DATABRICKS_SERVER_HOSTNAME")
    http_path = os.environ.get("DATABRICKS_HTTP_PATH")
    token = os.environ.get("DATABRICKS_TOKEN")
    if not all([host, http_path, token]):
        print("set DATABRICKS_SERVER_HOSTNAME, DATABRICKS_HTTP_PATH, DATABRICKS_TOKEN.", file=sys.stderr)
        return 2

    with dbsql.connect(server_hostname=host, http_path=http_path, access_token=token) as conn:
        with conn.cursor() as cur:
            tables = list_tables(cur, args.catalog, args.schema, args.like, args.limit)
        if not tables:
            print("no tables matched the scope.", file=sys.stderr)
            return 1

        # DRY-RUN (default): show exactly what WOULD run, execute nothing.
        if not args.run:
            print(CAUTION)
            print(f"DRY-RUN -- {len(tables)} table(s) would be analyzed. Nothing was run.")
            print("Re-run with --run --yes to execute (scope it down first if this list is large):\n")
            for c, s, t in tables:
                print(f"  ANALYZE TABLE `{c}`.`{s}`.`{t}` COMPUTE STORAGE METRICS;")
            return 0

        # Real run needs the explicit second confirmation.
        if not args.yes:
            print(CAUTION)
            print(f"Refusing to ANALYZE {len(tables)} table(s) without --yes.\n"
                  f"This is destructive/expensive; re-run with --run --yes to confirm.", file=sys.stderr)
            return 2

        print(CAUTION)
        print(f"Running ANALYZE on {len(tables)} table(s) (timeout {args.timeout}s each)...\n")
        with conn.cursor() as c0:
            c0.execute(f"SET STATEMENT_TIMEOUT = {int(args.timeout)}")

        scorecard = []
        for c, s, t in tables:
            fq_disp = f"{c}.{s}.{t}"
            t0 = time.time()
            try:
                with conn.cursor() as cur:
                    cur.execute(f"ANALYZE TABLE `{c}`.`{s}`.`{t}` COMPUTE STORAGE METRICS")
                    cols = [d[0] for d in cur.description] if cur.description else []
                    rows = cur.fetchall() if cur.description else []
                d = dict(zip(cols, rows[0])) if (cols and rows) else {}
                detail = (f"total={d.get('total_bytes')} active={d.get('active_bytes')} "
                          f"vacuumable={d.get('vacuumable_bytes')} time_travel={d.get('time_travel_bytes')}")
                scorecard.append((fq_disp, "OK", detail, f"{time.time() - t0:.1f}s"))
            except Exception as ex:  # noqa: BLE001 - one bad table must not abort the sweep
                outcome = classify_error(str(ex))
                scorecard.append((fq_disp, outcome, str(ex).splitlines()[0], f"{time.time() - t0:.1f}s"))

        print(f"\n{'table':52} {'outcome':12} {'storage metrics / reason':70} time")
        print("-" * 150)
        counts = {}
        for tbl, outcome, detail, dt in scorecard:
            counts[outcome] = counts.get(outcome, 0) + 1
            print(f"{tbl:52.52} {outcome:12} {detail:70.70} {dt}")
        print("-" * 150)
        print("  ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
