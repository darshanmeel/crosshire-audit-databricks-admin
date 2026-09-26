"""Parse one query profile JSON (as downloaded from the UI) into node rows and a summary.

The format is undocumented, so every key is looked up among a few candidate names, unknown
keys are ignored, and a missing graph means "no profile", not a failure. The key names
below are unconfirmed until checked against real downloaded files.

Only ids, numbers, operator names and table names leave this module. The profile also holds
the SQL text and filter literals; those are never read.
"""
import re

from crosshire_apps.common.fingerprint import fingerprint
from crosshire_apps.common.plan_shape import plan_hash

# Metric label (lower-cased) -> common column.
COMMON_METRICS = {
    "rows": "rows_output",
    "rows output": "rows_output",
    "number of output rows": "rows_output",
    "num output rows": "rows_output",
    "duration": "time_ms",
    "time": "time_ms",
    "time spent": "time_ms",
    "cumulative time": "time_ms",
    "peak memory": "peak_memory_bytes",
    "peak memory usage": "peak_memory_bytes",
    "spill size": "spill_bytes",
    "spilled bytes": "spill_bytes",
    "bytes spilled": "spill_bytes",
    "shuffle bytes written": "shuffle_write_bytes",
    "bytes sent": "shuffle_write_bytes",
    "shuffle bytes read": "shuffle_read_bytes",
    "bytes received": "shuffle_read_bytes",
    "files read": "files_read",
    "number of files read": "files_read",
    "files pruned": "files_pruned",
    "number of files pruned": "files_pruned",
    "bytes read": "bytes_read",
    "size of files read": "bytes_read",
    "bytes pruned": "bytes_pruned",
    "size of files pruned": "bytes_pruned",
}
NODE_COLUMNS = sorted(set(COMMON_METRICS.values()))
# keyMetrics field -> common column
KEY_METRICS = {"durationMs": "time_ms", "rowsNum": "rows_output", "peakMemoryBytes": "peak_memory_bytes"}

_TABLE_KEYS = {"table", "table name", "table_name", "tablename", "scan_table", "output table"}
_TABLE = re.compile(r"^`?[\w$-]+`?(\.`?[\w$-]+`?){1,2}$")
_JOIN_TYPE = re.compile(r"\b(inner|cross|left ?outer|right ?outer|full ?outer|left ?semi|left ?anti|existence)\b", re.I)
_SCAN_NAME = re.compile(r"^(?P<op>.*?Scan(?:\s+[a-z]\w*)?)\s+(?P<table>`?[\w$-]+`?(?:\.`?[\w$-]+`?){1,2})$")


def _first(d, *keys):
    for k in keys:
        if isinstance(d, dict) and d.get(k) is not None:
            return d[k]
    return None


def _number(v):
    if isinstance(v, bool):
        return None
    if isinstance(v, (int, float)):
        return int(v)
    if isinstance(v, dict):
        return _number(_first(v, "value", "total", "sum"))
    if isinstance(v, str) and re.fullmatch(r"-?\d+(\.\d+)?", v.strip()):
        return int(float(v))
    return None


def _graph(doc):
    """(nodes, edges) of the largest graph in the document, or ([], [])."""
    graphs = _first(doc, "graphs")
    if isinstance(graphs, list):
        candidates = [g for g in graphs if isinstance(g, dict)]
    else:
        g = _first(doc, "graph", "plan")
        candidates = [g] if isinstance(g, dict) else []
    candidates = [g for g in candidates if isinstance(g.get("nodes"), list)]
    if not candidates:
        return [], []
    g = max(candidates, key=lambda g: len(g["nodes"]))
    return [n for n in g["nodes"] if isinstance(n, dict)], [e for e in g.get("edges") or [] if isinstance(e, dict)]


def _table_name(node):
    for item in node.get("metadata") or []:
        if not isinstance(item, dict):
            continue
        key = str(_first(item, "key", "label", "name") or "").lower()
        if key in _TABLE_KEYS:
            values = _first(item, "values", "value")
            value = values[0] if isinstance(values, list) and values else values
            if isinstance(value, str) and _TABLE.match(value.strip()):
                return value.strip().replace("`", "")
    m = _SCAN_NAME.match(str(node.get("name") or ""))
    return m.group("table").replace("`", "") if m else None


def _join_type(node):
    name = str(node.get("name") or "")
    if "join" not in name.lower():
        return None
    for item in node.get("metadata") or []:
        if isinstance(item, dict) and "join type" in str(_first(item, "key", "label") or "").lower():
            values = _first(item, "values", "value")
            value = values[0] if isinstance(values, list) and values else values
            m = _JOIN_TYPE.search(str(value or ""))
            if m:
                return m.group(1).replace(" ", "").capitalize()
    m = _JOIN_TYPE.search(name)
    return m.group(1).replace(" ", "").capitalize() if m else None


def _metrics(node):
    cols = {c: None for c in NODE_COLUMNS}
    other = {}
    for key, col in KEY_METRICS.items():
        v = _number((node.get("keyMetrics") or {}).get(key))
        if v is not None:
            cols[col] = v
    for m in node.get("metrics") or []:
        if not isinstance(m, dict):
            continue
        label = str(_first(m, "label", "name", "key") or "").strip()
        value = _number(_first(m, "value", "values"))
        if not label or value is None:
            continue
        col = COMMON_METRICS.get(label.lower())
        if col and cols[col] is None:
            cols[col] = value
        else:
            other[label] = value
    return cols, dict(sorted(other.items()))


def parse_profile(doc):
    """Return (statement, nodes) or None when the document holds no operator graph."""
    if not isinstance(doc, dict):
        return None
    raw_nodes, edges = _graph(doc)
    if not raw_nodes:
        return None
    query = _first(doc, "query", "statement") or {}

    ids = [str(_first(n, "id", "nodeId")) for n in raw_nodes]
    # Edges point from the producing node to the consuming one (unconfirmed): child -> parent.
    parent = {}
    for e in edges:
        src, dst = _first(e, "fromId", "from", "source"), _first(e, "toId", "to", "target")
        if src is not None and dst is not None:
            parent.setdefault(str(src), str(dst))
    children = {}
    for child, p in parent.items():
        children.setdefault(p, []).append(child)

    by_id = dict(zip(ids, raw_nodes))
    # Stable ids: preorder position from the roots, so equal plans give equal node ids.
    order, stack = [], sorted((i for i in ids if i not in parent), reverse=True)
    seen = set()
    while stack:
        i = stack.pop()
        if i in seen or i not in by_id:
            continue
        seen.add(i)
        order.append(i)
        stack.extend(sorted(children.get(i, []), reverse=True))
    order += [i for i in ids if i not in seen]
    position = {i: n for n, i in enumerate(order)}

    nodes = []
    for i in order:
        n = by_id[i]
        cols, other = _metrics(n)
        nodes.append({
            "node_id": position[i],
            "parent_node_id": position.get(parent.get(i)),
            "node_name": str(_first(n, "name", "tag") or "UNKNOWN"),
            "node_tag": _first(n, "tag"),
            "join_type": _join_type(n),
            "table_name": _table_name(n),
            "is_hidden": bool(n.get("hidden")),
            "child_count": len(children.get(i, [])),
            **cols,
            "other_metrics": other,
        })

    error = _first(query, "errorMessage", "error_message")
    statement = {
        "statement_id": _first(query, "id", "queryId", "statementId", "statement_id"),
        "execution_status": _first(query, "status", "state"),
        "error_fingerprint": fingerprint(error) if error else None,
        "plan_hash": plan_hash(nodes),
    }
    return statement, nodes


def summarise(nodes):
    """The per-statement summary: slowest operators, spill/shuffle, join blow-up, pruning."""
    total = sum(n["time_ms"] or 0 for n in nodes) or None
    by_time = sorted((n for n in nodes if n["time_ms"]), key=lambda n: -n["time_ms"])[:3]
    rows = {n["node_id"]: n["rows_output"] for n in nodes}
    child_rows = {}
    for n in nodes:
        if n["parent_node_id"] is not None and n["rows_output"] is not None:
            child_rows[n["parent_node_id"]] = child_rows.get(n["parent_node_id"], 0) + n["rows_output"]

    joins = []
    for n in nodes:
        if "join" in n["node_name"].lower() and rows.get(n["node_id"]) is not None and child_rows.get(n["node_id"]):
            joins.append({
                "node_id": n["node_id"], "node_name": n["node_name"], "rows_in": child_rows[n["node_id"]],
                "rows_out": rows[n["node_id"]], "blow_up": round(rows[n["node_id"]] / child_rows[n["node_id"]], 3),
            })

    scans = {}
    for n in nodes:
        if n["table_name"] and (n["files_read"] is not None or n["files_pruned"] is not None):
            s = scans.setdefault(n["table_name"], {"table_name": n["table_name"], "files_read": 0, "files_pruned": 0,
                                                   "bytes_read": 0, "bytes_pruned": 0})
            for k in ("files_read", "files_pruned", "bytes_read", "bytes_pruned"):
                s[k] += n[k] or 0

    return {
        "total_operator_time_ms": total,
        "slowest_operators": [
            {"node_id": n["node_id"], "node_name": n["node_name"], "time_ms": n["time_ms"],
             "time_share": round(n["time_ms"] / total, 4) if total else None}
            for n in by_time
        ],
        "spill_by_operator": [
            {"node_id": n["node_id"], "node_name": n["node_name"], "bytes": n["spill_bytes"]}
            for n in nodes if n["spill_bytes"]
        ],
        "shuffle_by_operator": [
            {"node_id": n["node_id"], "node_name": n["node_name"],
             "bytes": (n["shuffle_write_bytes"] or 0) + (n["shuffle_read_bytes"] or 0)}
            for n in nodes if n["shuffle_write_bytes"] or n["shuffle_read_bytes"]
        ],
        "join_blow_up": joins,
        "scan_pruning": sorted(scans.values(), key=lambda s: s["table_name"]),
    }
