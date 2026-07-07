"""Shared parser for the v2 SQL header schema.

Every query file in queries/<domain>/*.sql opens with a comment header. This module
parses that header into a dict. It is the single source of truth for the header contract:
build_manifest.py and lint_headers.py both import it. See CONTRIBUTING.md for the schema.

Stdlib only — no third-party dependencies.
"""
from __future__ import annotations

import re
from pathlib import Path

# The 14 canonical header fields, in schema order. `tier` rides on the `domain:` line.
FIELDS = [
    "query_id",
    "title",
    "domain",
    "reads",
    "requires",
    "params",
    "confidence",
    "confidence_note",
    "read_this",
    "healthy",
    "investigate_if",
    "actions",
    "next",
    "caveats",
]

CONFIDENCE_ENUM = {"confirmed", "needs_confirmation"}
TIER_ENUM = {"lite", "standard", "deep"}
DOMAINS = {
    "cost",
    "performance",
    "compute",
    "jobs_pipelines",
    "serving_ai",
    "storage",
    "governance_access",
}

# First-audit picks (the ten ★ queries). Kept here so the manifest is deterministic;
# documented in README.md and CONTRIBUTING.md.
STARS = {
    "cost_actual_vs_list_by_sku",
    "cost_by_job",
    "cost_chargeback_by_tag",
    "cost_dollarized_by_sku_day",
    "cost_premium_serverless_photon",
    "query_costly_statements",
    "compute_warehouse_idle_gaps",
    "lakeflow_failed_jobs_wasted_dbus",
    "lakeflow_jobs_on_all_purpose",
    "access_runas_escalation",
}

REPO = "https://github.com/darshanmeel/crosshire-audit-databricks-admin/blob/master/queries"
LEARN = "/learn/tech/databricks/audit"

_FIELD_RE = re.compile(r"^--\s*(" + "|".join(FIELDS) + r")\s*:\s?(.*)$")
_DOMAIN_RE = re.compile(r"^\s*(\S+)\s+tier\s*:\s*(\S+)\s*$")
_PARAM_RE = re.compile(r":(\w+)\s*\(default\s+([^)]+)\)\s*(.*)")
# A next-token is a query_id optionally followed by a parenthetical condition.
# The condition may itself contain commas, so we split the field only on TOP-LEVEL commas.
_NEXT_SPLIT_RE = re.compile(r",(?![^(]*\))")
_NEXT_RE = re.compile(r"^([a-z0-9_]+)\s*(?:\(\s*(?:if\s+)?(.*?)\s*\))?$", re.I)
_ACTION_SPLIT_RE = re.compile(r"\s*\d+\)\s*")


class HeaderError(ValueError):
    pass


def _raw_fields(text: str) -> dict[str, str]:
    """Extract raw (string) field values from the leading comment block."""
    fields: dict[str, str] = {}
    current: str | None = None
    for line in text.splitlines():
        if not line.startswith("--"):
            # First non-comment line ends the header block.
            break
        m = _FIELD_RE.match(line)
        if m:
            current = m.group(1)
            fields[current] = m.group(2).strip()
        else:
            # Continuation line: append to the field in progress.
            cont = line[2:].strip()
            if current is not None and cont:
                fields[current] = (fields[current] + " " + cont).strip()
    return fields


def parse_params(value: str) -> list[dict]:
    out = []
    for chunk in value.split(";"):
        chunk = chunk.strip()
        if not chunk:
            continue
        m = _PARAM_RE.search(chunk)
        if not m:
            continue
        name, default, meaning = m.group(1), m.group(2).strip(), m.group(3).strip()
        val: object = default
        try:
            val = int(default)
        except ValueError:
            try:
                val = float(default)
            except ValueError:
                val = default
        out.append({"name": name, "default": val, "meaning": meaning})
    return out


def parse_next(value: str) -> list[dict]:
    out = []
    if not value or value.strip().lower().startswith("n/a"):
        return out
    for token in value.split(","):
        token = token.strip()
        if not token:
            continue
        m = _NEXT_RE.match(token)
        if not m:
            continue
        out.append({"query_id": m.group(1), "if": (m.group(2) or "").strip()})
    return out


def parse_actions(value: str) -> list[str]:
    if not value or value.strip().lower().startswith("n/a"):
        return []
    parts = [p.strip() for p in _ACTION_SPLIT_RE.split(value) if p.strip()]
    return parts


def parse_reads(value: str) -> list[str]:
    return [r.strip() for r in value.split(",") if r.strip()]


def parse_header(text: str, *, path: str = "<memory>") -> dict:
    """Parse a full SQL file's text into a structured header dict.

    Raises HeaderError on a structurally-broken header (missing required field or
    malformed domain line). Value-level validation lives in lint_headers.py.
    """
    raw = _raw_fields(text)
    for f in FIELDS:
        if f not in raw:
            raise HeaderError(f"{path}: missing required header field '{f}'")

    dm = _DOMAIN_RE.match(raw["domain"])
    if not dm:
        raise HeaderError(
            f"{path}: 'domain:' line must read '<domain>   tier: <tier>', got {raw['domain']!r}"
        )
    domain, tier = dm.group(1), dm.group(2)

    return {
        "query_id": raw["query_id"].strip(),
        "title": raw["title"].strip(),
        "domain": domain,
        "tier": tier,
        "stars": raw["query_id"].strip() in STARS,
        "reads": parse_reads(raw["reads"]),
        "requires": raw["requires"].strip(),
        "params": parse_params(raw["params"]),
        "confidence": raw["confidence"].strip(),
        "confidence_note": raw["confidence_note"].strip(),
        "read_this": raw["read_this"].strip(),
        "healthy": raw["healthy"].strip(),
        "investigate_if": raw["investigate_if"].strip(),
        "actions": parse_actions(raw["actions"]),
        "next": parse_next(raw["next"]),
        "caveats": raw["caveats"].strip(),
        "_raw": raw,
    }


def iter_query_files(queries_dir: Path):
    for p in sorted(queries_dir.rglob("*.sql")):
        yield p


def load_all(queries_dir: Path) -> dict[str, dict]:
    """query_id -> parsed header, for every .sql under queries_dir."""
    out = {}
    for p in iter_query_files(queries_dir):
        hdr = parse_header(p.read_text(encoding="utf-8"), path=str(p))
        out[hdr["query_id"]] = hdr
    return out
