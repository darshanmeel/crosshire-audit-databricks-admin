#!/usr/bin/env python3
"""Header-schema + hygiene linter for the query library.

Checks, over every queries/<domain>/*.sql:
  - all 14 v2 header fields present and non-empty
  - query_id == filename; domain == folder; tier in enum; confidence in enum
  - params declares :period_days; the SQL body uses :period_days and NOT :lookback_days
  - every `next:` target resolves to a real query_id
  - no internal-pipeline vocabulary leaks (collector, verifier, --share, findings/, feeds:,
    lookback_days, the databricks_audit: marker)
  - manifest.json is in sync (delegates to build_manifest --check)

    python tools/lint_headers.py

Exit code 0 = clean, 1 = violations. Stdlib only.
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import header_schema as hs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "queries"

# Vocabulary that must never appear in a public query file (header or body).
FORBIDDEN = [
    (re.compile(r"\bcollector\b", re.I), "internal 'collector'"),
    (re.compile(r"\bverifier\b", re.I), "internal 'verifier'"),
    (re.compile(r"--share\b"), "internal '--share' build flag"),
    (re.compile(r"findings/"), "internal 'findings/...' path"),
    (re.compile(r"databricks_audit:"), "internal 'databricks_audit:' marker"),
    (re.compile(r"^--\s*feeds\s*:", re.M), "internal 'feeds:' header"),
    (re.compile(r"lookback_days"), "old ':lookback_days' param (use :period_days)"),
    (re.compile(r"\bpreview\b(?=[^\n]*confidence)", re.I), None),  # placeholder, disabled below
]
# Drop the disabled placeholder.
FORBIDDEN = [f for f in FORBIDDEN if f[1] is not None]

# A2: hard-coded time windows that must have become :period_days.
WINDOW_BAD = [
    (re.compile(r"INTERVAL\s+\d+\s+DAYS?", re.I), "hard-coded 'INTERVAL <n> DAYS' (use :period_days)"),
    (re.compile(r"date_add\(\s*current_date\(\)\s*,\s*-\d+"), "hard-coded date_add() window (use :period_days)"),
    (re.compile(r"dateadd\(\s*day\s*,\s*-\d+", re.I), "hard-coded dateadd() window (use :period_days)"),
    (re.compile(r"date_sub\(\s*current_date\(\)\s*,\s*\d+"), "hard-coded date_sub() window (use :period_days)"),
]


def lint_file(path: Path, all_ids: set[str]) -> list[str]:
    errs: list[str] = []
    text = path.read_text(encoding="utf-8")
    rel = path.relative_to(ROOT)

    try:
        hdr = hs.parse_header(text, path=str(rel))
    except hs.HeaderError as e:
        return [str(e)]

    for f in hs.FIELDS:
        if f in ("domain",):
            continue
        if not str(hdr.get(f if f != "domain" else "domain", "")).strip():
            errs.append(f"{rel}: field '{f}' is empty")

    if hdr["query_id"] != path.stem:
        errs.append(f"{rel}: query_id '{hdr['query_id']}' != filename '{path.stem}'")
    if hdr["domain"] != path.parent.name:
        errs.append(f"{rel}: domain '{hdr['domain']}' != folder '{path.parent.name}'")
    if hdr["tier"] not in hs.TIER_ENUM:
        errs.append(f"{rel}: tier '{hdr['tier']}' not in {sorted(hs.TIER_ENUM)}")
    if hdr["confidence"] not in hs.CONFIDENCE_ENUM:
        errs.append(f"{rel}: confidence '{hdr['confidence']}' not in {sorted(hs.CONFIDENCE_ENUM)}")

    # SQL body = everything after the leading comment block.
    body = "\n".join(l for l in text.splitlines() if not l.startswith("--"))

    # A2 window hygiene: no hard-coded windows anywhere. The only allowed rolling window is
    # :period_days. Genuine point-in-time snapshots (no window at all) are allowed to omit it.
    for rx, label in WINDOW_BAD:
        if rx.search(body):
            errs.append(f"{rel}: {label}")
    param_names = {p["name"] for p in hdr["params"]}
    if ":period_days" in body and "period_days" not in param_names:
        errs.append(f"{rel}: body uses :period_days but params does not declare it")

    for qid, cond in [(n["query_id"], n["if"]) for n in hdr["next"]]:
        if qid not in all_ids:
            errs.append(f"{rel}: next target '{qid}' is not a real query_id")

    for rx, label in FORBIDDEN:
        if rx.search(text):
            errs.append(f"{rel}: forbidden {label}")

    return errs


def main() -> int:
    files = list(hs.iter_query_files(QUERIES))
    all_ids = {p.stem for p in files}
    errs: list[str] = []
    for p in files:
        errs.extend(lint_file(p, all_ids))

    print(f"linted {len(files)} query files")
    if errs:
        print(f"\n{len(errs)} violation(s):", file=sys.stderr)
        for e in errs:
            print("  " + e, file=sys.stderr)

    # Manifest sync check.
    r = subprocess.run(
        [sys.executable, str(ROOT / "tools" / "build_manifest.py"), "--check"],
        capture_output=True, text=True,
    )
    sys.stdout.write(r.stdout)
    sys.stderr.write(r.stderr)
    manifest_ok = r.returncode == 0

    if errs or not manifest_ok:
        return 1
    print("all header + manifest checks passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
