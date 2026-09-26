import json

from crosshire_apps.classic.plan import parse_plan
from tests.synthetic import final_plan, initial_plan


def test_nodes_are_preorder_with_parents_tables_and_join_type():
    h, nodes = parse_plan(json.dumps(final_plan()))
    names = [(n["node_id"], n["parent_node_id"], n["node_name"], n["table_name"], n["join_type"]) for n in nodes]
    assert names == [
        (0, None, "AdaptiveSparkPlan", None, None),
        (1, 0, "HashAggregate", None, None),
        (2, 1, "Exchange", None, None),
        (3, 2, "BroadcastHashJoin", None, "Inner"),
        (4, 3, "Scan parquet", "main.sales.orders", None),
        (5, 3, "BroadcastExchange", None, None),
        (6, 5, "Scan parquet", "main.sales.customers", None),
    ]
    assert h and len(h) == 16


def test_no_literal_is_kept():
    _, nodes = parse_plan(json.dumps(final_plan()))
    assert "PRIVATE" not in json.dumps(nodes)
    assert "bob@" not in json.dumps(nodes)


def test_plan_hash_ignores_values_and_codegen_ids_but_sees_shape():
    a = final_plan()
    b = json.loads(json.dumps(a).replace("PRIVATE_LITERAL", "OTHER").replace('"accumulatorId": 5', '"accumulatorId": 55'))
    assert parse_plan(json.dumps(a))[0] == parse_plan(json.dumps(b))[0]
    assert parse_plan(json.dumps(a))[0] != parse_plan(json.dumps(initial_plan()))[0]
    c1 = {"nodeName": "WholeStageCodegen (1)", "children": []}
    c2 = {"nodeName": "WholeStageCodegen (7)", "children": []}
    assert parse_plan(json.dumps(c1))[0] == parse_plan(json.dumps(c2))[0]


def test_write_target_from_quoted_identifier_only():
    w = {"nodeName": "Execute InsertIntoHadoopFsRelationCommand",
         "simpleString": "Execute InsertIntoHadoopFsRelationCommand s3://b/p, false, Parquet, "
                         "[path=s3://b/p], Append, `spark_catalog`.`db`.`t`, [a]"}
    _, nodes = parse_plan(json.dumps(w))
    assert nodes[0]["table_name"] == "spark_catalog.db.t" and nodes[0]["is_write"]


def test_bad_json_means_no_plan():
    assert parse_plan("{not json") == (None, [])
