import datetime as dt

import pytest

from crosshire_apps.profiles import job
from tests.profile_samples import failed, slow_join

SCHEMA = "profile_test"
DAY = "2026-09-25"
JOIN_ID = "11111111-2222-3333-4444-555555555555"


@pytest.fixture(scope="module")
def history(spark):
    spark.sql(f"DROP DATABASE IF EXISTS {SCHEMA} CASCADE")
    spark.sql(f"CREATE DATABASE {SCHEMA}")
    end = dt.datetime(2026, 9, 25, 12)
    rows = [
        # statement_id, status, duration, spilled, task ms
        (JOIN_ID, "FINISHED", 900_000, 0, 10_000_000),   # slow
        ("f", "FAILED", 1_000, 0, 10),                    # failed
        ("gone", "FINISHED", 1_000, 5, 10),               # spilled; profile no longer there
        ("denied", "FINISHED", 1_000, 5, 10),             # spilled; endpoint refuses
        ("fine", "FINISHED", 1_000, 0, 1),                # nothing wrong: not chosen
    ]
    data = [(sid, "ws1", {"type": "WAREHOUSE", "warehouse_id": "wh1"}, st, dur, sp, task, end,
             {"job_info": {"job_task_run_id": 42 if sid == JOIN_ID else None}})
            for sid, st, dur, sp, task in rows]
    schema = ("statement_id string, workspace_id string, compute struct<type:string,warehouse_id:string>, "
              "execution_status string, total_duration_ms bigint, spilled_local_bytes bigint, "
              "total_task_duration_ms bigint, end_time timestamp, "
              "query_source struct<job_info:struct<job_task_run_id:bigint>>")
    spark.createDataFrame(data, schema).write.saveAsTable(f"{SCHEMA}.history")
    return f"{SCHEMA}.history"


CALLS = []


def fake_fetch(statement_id):
    CALLS.append(statement_id)
    return {JOIN_ID: ("ok", slow_join()), "f": ("ok", failed()), "gone": ("ok", {"query": {}}),
            "denied": ("refused", None)}[statement_id]


def run(spark, history):
    job.run(spark, fake_fetch, SCHEMA, slow_seconds=300, top_n=0, cap=10, history_table=history, day=DAY)


def test_selects_fetches_and_writes(spark, history):
    run(spark, history)
    assert sorted(CALLS) == sorted([JOIN_ID, "f", "gone", "denied"])
    log = {r.statement_id: r.result for r in spark.table(f"{SCHEMA}.query_profile_fetch_log").collect()}
    assert log == {JOIN_ID: "ok", "f": "ok", "gone": "not found", "denied": "refused"}
    s = spark.table(f"{SCHEMA}.query_profile_summary").where(f"statement_id = '{JOIN_ID}'").first()
    assert (s.workspace_id, s.compute_type, s.warehouse_id, s.job_task_run_id) == ("ws1", "WAREHOUSE", "wh1", "42")
    assert s.slowest_operators[0].node_name == "Inner Join"
    assert spark.table(f"{SCHEMA}.query_profile_nodes").where(f"statement_id = '{JOIN_ID}'").count() == 6


def test_rerun_skips_statements_that_have_a_profile(spark, history):
    CALLS.clear()
    before = sorted(map(str, spark.table(f"{SCHEMA}.query_profile_nodes").collect()))
    run(spark, history)
    assert sorted(CALLS) == ["denied", "gone"]  # only the ones without a profile are asked again
    assert sorted(map(str, spark.table(f"{SCHEMA}.query_profile_nodes").collect())) == before


def test_privacy(spark, history):
    for t in job.OUTPUT_TABLES:
        for row in spark.table(f"{SCHEMA}.{t}").toJSON().collect():
            assert "PRIVATE" not in row and "SECRET" not in row


def test_stops_after_repeated_refusals():
    calls = []

    def refuse(sid):
        calls.append(sid)
        return "refused", None

    out = job.fetch_all(refuse, [str(i) for i in range(50)])
    assert len(out) < 50 and len(calls) <= job.STOP_AFTER_REFUSALS + job.CONCURRENCY


def test_api_source_retries_then_maps_status(monkeypatch):
    replies = iter([(429, "", b""), (503, "", b""), (200, "application/json", b'{"graphs": []}')])
    monkeypatch.setattr(job, "probe", lambda *a: next(replies))
    monkeypatch.setattr(job.time, "sleep", lambda s: None)
    fetch = job.api_source("curl 'https://h/graphql/x' --data-raw '{\"id\":\"{statement_id}\"}'", "https://h", "t")
    assert fetch("abc") == ("ok", {"graphs": []})
    monkeypatch.setattr(job, "probe", lambda *a: (403, "", b""))
    assert fetch("abc") == ("refused", None)
    monkeypatch.setattr(job, "probe", lambda *a: (404, "", b""))
    assert fetch("abc") == ("not found", None)
