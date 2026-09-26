"""Hand-made query profiles in the assumed download shape (graphs > nodes/edges).

The shape is unconfirmed; replace it with the key tree of a real downloaded file when we
have one. PRIVATE/SECRET markers must never reach a table.
"""


def metric(label, value):
    return {"key": label.upper().replace(" ", "_"), "label": label, "value": value}


def node(nid, name, key=None, metrics=(), metadata=(), tag=None):
    return {"id": str(nid), "name": name, "tag": tag or name.upper(), "hidden": False,
            "keyMetrics": key or {}, "metrics": list(metrics), "metadata": list(metadata)}


def slow_join():
    nodes = [
        node(1, "Result", {"durationMs": 5, "rowsNum": 10}),
        node(2, "Aggregate", {"durationMs": 300, "rowsNum": 10, "peakMemoryBytes": 4096},
             [metric("Spill size", 2048)]),
        node(3, "Shuffle", {"durationMs": 200}, [metric("Shuffle bytes written", 999), metric("Some new metric", 7)]),
        node(4, "Inner Join", {"durationMs": 4000, "rowsNum": 50000},
             metadata=[{"key": "JOIN_TYPE", "label": "Join type", "values": ["Inner"]},
                       {"key": "JOIN_CONDITION", "label": "Join condition", "values": ["a.email = 'PRIVATE@x.com'"]}]),
        node(5, "Scan main.sales.orders", {"durationMs": 1000, "rowsNum": 1000},
             [metric("Files read", 12), metric("Files pruned", 88), metric("Bytes read", 5000)],
             [{"key": "TABLE_NAME", "label": "Table", "values": ["main.sales.orders"]},
              {"key": "FILTERS", "label": "Filters", "values": ["amount > 12345 AND name = 'PRIVATE'"]}]),
        node(6, "Scan main.sales.customers", {"durationMs": 500, "rowsNum": 100},
             [metric("Files read", 2)]),
    ]
    edges = [{"fromId": "2", "toId": "1"}, {"fromId": "3", "toId": "2"}, {"fromId": "4", "toId": "3"},
             {"fromId": "5", "toId": "4"}, {"fromId": "6", "toId": "4"}]
    return {
        "query": {"id": "11111111-2222-3333-4444-555555555555", "status": "FINISHED",
                  "queryText": "SELECT * FROM orders WHERE email = 'PRIVATE@x.com' -- SECRET"},
        "graphs": [{"nodes": nodes[:1], "edges": []}, {"nodes": nodes, "edges": edges}],
    }


def failed():
    return {"query": {"id": "f", "status": "FAILED",
                      "errorMessage": "[DIVIDE_BY_ZERO] Division by zero in 'PRIVATE'"},
            "graphs": [{"nodes": [node(1, "Project", {"rowsNum": 0})], "edges": []}]}
