import json

from crosshire_apps.profiles.parser import parse_profile, summarise
from tests.profile_samples import failed, slow_join


def test_nodes_tree_metrics_and_tables():
    statement, nodes = parse_profile(slow_join())
    assert statement["statement_id"] == "11111111-2222-3333-4444-555555555555"
    got = [(n["node_id"], n["parent_node_id"], n["node_name"], n["table_name"]) for n in nodes]
    assert got == [(0, None, "Result", None), (1, 0, "Aggregate", None), (2, 1, "Shuffle", None),
                   (3, 2, "Inner Join", None), (4, 3, "Scan main.sales.orders", "main.sales.orders"),
                   (5, 3, "Scan main.sales.customers", "main.sales.customers")]
    agg, shuffle, join, orders = nodes[1], nodes[2], nodes[3], nodes[4]
    assert (agg["time_ms"], agg["rows_output"], agg["peak_memory_bytes"], agg["spill_bytes"]) == (300, 10, 4096, 2048)
    assert shuffle["shuffle_write_bytes"] == 999 and shuffle["other_metrics"] == {"Some new metric": 7}
    assert join["join_type"] == "Inner"
    assert (orders["files_read"], orders["files_pruned"], orders["bytes_read"]) == (12, 88, 5000)


def test_summary():
    _, nodes = parse_profile(slow_join())
    s = summarise(nodes)
    assert [o["node_name"] for o in s["slowest_operators"]] == ["Inner Join", "Scan main.sales.orders",
                                                               "Scan main.sales.customers"]
    assert s["slowest_operators"][0]["time_share"] == round(4000 / 6005, 4)
    assert s["spill_by_operator"] == [{"node_id": 1, "node_name": "Aggregate", "bytes": 2048}]
    assert s["join_blow_up"][0]["rows_in"] == 1100 and s["join_blow_up"][0]["blow_up"] == round(50000 / 1100, 3)
    assert s["scan_pruning"][1] == {"table_name": "main.sales.orders", "files_read": 12, "files_pruned": 88,
                                    "bytes_read": 5000, "bytes_pruned": 0}


def test_no_sql_text_or_literals_survive():
    parsed = parse_profile(slow_join())
    out = json.dumps([parsed, summarise(parsed[1])])
    assert "PRIVATE" not in out and "SECRET" not in out and "12345" not in out


def test_failed_keeps_fingerprint_only():
    statement, _ = parse_profile(failed())
    assert statement["execution_status"] == "FAILED" and len(statement["error_fingerprint"]) == 16


def test_missing_graph_means_no_profile():
    assert parse_profile({"query": {"id": "x"}}) is None
    assert parse_profile({"graphs": "weird"}) is None
    assert parse_profile([]) is None


def test_plan_hash_ignores_ids_and_numbers():
    a, b = slow_join(), slow_join()
    for n in b["graphs"][1]["nodes"]:
        n["keyMetrics"] = {"durationMs": 1}
    assert parse_profile(a)[0]["plan_hash"] == parse_profile(b)[0]["plan_hash"]
