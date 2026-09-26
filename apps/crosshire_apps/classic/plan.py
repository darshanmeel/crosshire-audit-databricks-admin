"""Turn a Spark `sparkPlanInfo` JSON tree into flat plan-node rows.

Only the node name, the join type, a table name and the metric definitions are kept.
`simpleString` holds filter literals, so it is read for the join type and write target only
and never stored.
"""
import json
import re

from crosshire_apps.common.plan_shape import plan_hash

_CODEGEN_ID = re.compile(r"\s*\(\d+\)$")
_IDENT = r"[A-Za-z_][\w$-]*"
_TABLE = rf"`?{_IDENT}`?(?:\.`?{_IDENT}`?){{1,2}}"
# "Scan parquet spark_catalog.db.t", "PhotonScan parquet main.s.t", "BatchScan main.s.t"
_SCAN = re.compile(rf"^(?P<op>\w*Scan(?:\s+[a-z]\w*)?)\s+(?P<table>{_TABLE})$")
# A write's target shows up in simpleString as a backtick-quoted catalog identifier.
_QUOTED_TABLE = re.compile(r"`([^`/]+)`\.`([^`/]+)`(?:\.`([^`/]+)`)?")
_WRITE = re.compile(r"(Insert|Write|Append|Overwrite|CreateTable|CreateDelta|ReplaceTable|AsSelect|SaveInto|Merge)")
_JOIN_TYPE = re.compile(r"\b(Inner|Cross|LeftOuter|RightOuter|FullOuter|LeftSemi|LeftAnti|ExistenceJoin)\b")

# Spark SQL metric name -> common column. Photon names still to confirm on real logs.
COMMON_METRICS = {
    "number of output rows": "rows_output",
    "num output rows": "rows_output",
    "spill size": "spill_bytes",
    "peak memory": "peak_memory_bytes",
    "shuffle bytes written": "shuffle_write_bytes",
    "remote bytes read": "shuffle_read_bytes",
    "local bytes read": "shuffle_read_bytes",
    "number of files read": "files_read",
    "number of files pruned": "files_pruned",
    "size of files read": "bytes_read",
    "number of written files": "files_written",
}
TIMING_TYPES = ("timing", "nsTiming")


def _table_name(raw_name, simple_string, is_write):
    m = _SCAN.match(raw_name)
    if m:
        return m.group("op"), m.group("table").replace("`", "")
    if is_write and simple_string:
        q = _QUOTED_TABLE.search(simple_string)
        if q:
            return raw_name, ".".join(p for p in q.groups() if p)
    return raw_name, None


def parse_plan(plan_json):
    """Return (plan_hash, nodes) for one sparkPlanInfo JSON string; (None, []) if unusable."""
    try:
        root = json.loads(plan_json) if isinstance(plan_json, str) else plan_json
    except ValueError:
        return None, []
    if not isinstance(root, dict):
        return None, []

    nodes = []
    stack = [(root, None)]
    while stack:
        node, parent_id = stack.pop()
        node_id = len(nodes)
        raw_name = _CODEGEN_ID.sub("", str(node.get("nodeName") or "")).strip()
        simple = node.get("simpleString") or ""
        is_write = bool(_WRITE.search(raw_name))
        node_name, table = _table_name(raw_name, simple, is_write)
        join = _JOIN_TYPE.search(simple) if "Join" in raw_name else None
        children = [c for c in (node.get("children") or []) if isinstance(c, dict)]
        metrics = [
            {
                "name": m.get("name"),
                "accumulator_id": int(m["accumulatorId"]),
                "metric_type": m.get("metricType"),
            }
            for m in (node.get("metrics") or [])
            if isinstance(m, dict) and m.get("accumulatorId") is not None
        ]
        nodes.append(
            {
                "node_id": node_id,
                "parent_node_id": parent_id,
                "node_name": node_name,
                "join_type": join.group(1) if join else None,
                "table_name": table,
                "is_write": is_write,
                "child_count": len(children),
                "metrics": metrics,
            }
        )
        # Reversed so the first child is visited first (preorder, like the Spark UI).
        for child in reversed(children):
            stack.append((child, node_id))
    return plan_hash(nodes), nodes
