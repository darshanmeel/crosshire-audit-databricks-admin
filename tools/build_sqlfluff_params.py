#!/usr/bin/env python3
"""Generate .sqlfluff's placeholder params FROM the v2 SQL headers (single source of truth).

sqlfluff's placeholder templater needs a value for every :param so it can parse the SQL. Those
values used to be hand-maintained in .sqlfluff, disconnected from each query's `-- params:` header
-- so they drift (add a threshold and forget .sqlfluff; rename a param; edit a default in one place
only). This regenerates .sqlfluff from the header defaults so the two can never disagree.

    python tools/build_sqlfluff_params.py           # regenerate .sqlfluff in place
    python tools/build_sqlfluff_params.py --check    # exit 1 if .sqlfluff is stale (CI)

Stdlib only.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import header_schema as hs  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
QUERIES = ROOT / "queries"
SQLFLUFF = ROOT / ".sqlfluff"

# Fixed preamble. Layout/lint is intentionally NOT enforced (max_line_length = 0, --rules PRS in CI):
# sqlfluff is advisory and cannot fully parse Databricks-specific syntax, so the header linter is the
# real gate. Do not "fix" max_line_length or add style rules here.
PREAMBLE = """\
# sqlfluff config (OPTIONAL / advisory CI check).
# The authoritative gate is tools/lint_headers.py; sqlfluff only sanity-parses the SQL, and the
# job is continue-on-error. Layout/style is deliberately NOT enforced (max_line_length = 0,
# --rules PRS = parse-errors only) because sqlfluff can't fully parse Databricks syntax.
#
# GENERATED from the query `-- params:` headers by tools/build_sqlfluff_params.py.
# DO NOT hand-edit the [sqlfluff:templater:placeholder] values below -- they must match the header
# defaults (CI runs `build_sqlfluff_params.py --check`). To change one, edit the query header and
# rerun: python tools/build_sqlfluff_params.py
[sqlfluff]
dialect = databricks
templater = placeholder
max_line_length = 0

[sqlfluff:templater:placeholder]
param_style = colon
"""


def header_param_defaults() -> dict[str, object]:
    """name -> default, gathered from every query header.

    A few threshold params are declared in more than one query and may carry different defaults
    (each query is self-consistent; run_audit uses each query's OWN default). The .sqlfluff value
    is parse-only, so we pick the first-seen default deterministically (files iterate sorted) and
    print the disagreement to stderr as an advisory — it is not fatal, and it never changes query
    behaviour.
    """
    out: dict[str, object] = {}
    conflicts: dict[str, set[str]] = {}
    for p in hs.iter_query_files(QUERIES):  # sorted -> deterministic first-seen
        hdr = hs.parse_header(p.read_text(encoding="utf-8"), path=str(p))
        for pr in hdr["params"]:
            name, default = pr["name"], pr["default"]
            if name in out:
                if str(out[name]) != str(default):
                    conflicts.setdefault(name, {str(out[name])}).add(str(default))
                continue  # keep the first-seen value for the placeholder
            out[name] = default
    for name in sorted(conflicts):
        print(f"note: :{name} has differing header defaults {sorted(conflicts[name])}; "
              f"using {out[name]!r} for the sqlfluff placeholder (parse-only)", file=sys.stderr)
    return out


def render() -> str:
    params = header_param_defaults()
    lines = [f"{name} = {params[name]}" for name in sorted(params)]
    return PREAMBLE + "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if .sqlfluff is stale")
    args = ap.parse_args()

    text = render()
    if args.check:
        current = SQLFLUFF.read_text(encoding="utf-8") if SQLFLUFF.exists() else ""
        if current != text:
            print(".sqlfluff is STALE — run: python tools/build_sqlfluff_params.py", file=sys.stderr)
            return 1
        print(".sqlfluff params are in sync.")
        return 0
    SQLFLUFF.write_text(text, encoding="utf-8")
    print(f"wrote {SQLFLUFF} ({len(header_param_defaults())} placeholder params from headers)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
