import datetime as dt

import pytest

from crosshire_apps.classic import job
from tests import synthetic as syn

SCHEMA = "classic_test"
FUTURE = dt.datetime(2099, 1, 1)


@pytest.fixture(scope="module")
def logs(spark, tmp_path_factory):
    root = tmp_path_factory.mktemp("logs")
    active = syn.write_cluster(str(root))
    spark.sql(f"DROP DATABASE IF EXISTS {SCHEMA} CASCADE")
    spark.sql(f"CREATE DATABASE {SCHEMA}")
    job.run(spark, [str(root)], SCHEMA, "all", slow_seconds=3600)
    return root, active


def rows(spark, table, order="1"):
    return spark.sql(f"SELECT * FROM {SCHEMA}.{table} ORDER BY {order}").collect()


def statement(spark, eid):
    r = spark.sql(f"SELECT * FROM {SCHEMA}.classic_statement_history WHERE execution_id = {eid}").collect()
    return r[0] if r else None


def test_statement_rows(spark, logs):
    s0 = statement(spark, 0)
    assert s0.statement_id == f"{syn.CLUSTER}:1234567890:0"
    assert s0.execution_status == "FINISHED"
    assert s0.total_duration_ms == 9090
    # stage 0: 3 ok + fetch failed + killed; stage 1: 2 ok + OOM
    assert (s0.task_count, s0.failed_task_count, s0.stage_count) == (8, 3, 2)
    assert s0.total_task_duration_ms == 100 + 200 + 4000 + 50 + 60 + 300 + 300 + 70
    assert s0.read_bytes == 11000 and s0.read_rows == 800
    assert s0.shuffle_read_bytes == 8 + 1000  # 1 local byte per task + remote
    assert s0.shuffle_write_bytes == 1024
    assert (s0.spilled_local_bytes, s0.memory_spilled_bytes) == (2048, 4096)
    assert s0.gc_time_ms == 40
    # worst stage is stage 0; percentiles are log-bucketed (within ~9%)
    assert s0.worst_stage_id == 0 and s0.max_task_ms == 4000
    assert 180 <= s0.p50_task_ms <= 220 and 3600 <= s0.p95_task_ms <= 4400
    assert s0.read_files == 12 and s0.produced_rows == 20
    assert s0.read_tables == ["main.sales.customers", "main.sales.orders"]
    assert (s0.job_id, s0.task_run_id, s0.job_run_id, s0.workspace_id) == ("111", "222", "333", "9876543210")
    assert s0.job_link_source == "job_properties"
    assert s0.error_message is None


def test_failed_statement_keeps_only_a_fingerprint(spark, logs):
    s1 = statement(spark, 1)
    assert s1.execution_status == "FAILED"
    assert len(s1.error_message) == 16


def test_open_statement_waits_for_its_end(spark, logs):
    assert statement(spark, 2) is None


def test_plan_nodes_use_final_adaptive_plan(spark, logs):
    s0 = statement(spark, 0)
    nodes = spark.sql(f"SELECT * FROM {SCHEMA}.classic_query_profile_nodes WHERE statement_id = '{s0.statement_id}'"
                      " ORDER BY node_id").collect()
    by_name = {n.node_name: n for n in nodes}
    assert "BroadcastHashJoin" in by_name and "SortMergeJoin" not in by_name
    join = by_name["BroadcastHashJoin"]
    assert join.join_type == "Inner" and join.rows_output == 1000
    agg = by_name["HashAggregate"]
    assert (agg.spill_bytes, agg.peak_memory_bytes, agg.time_ms, agg.rows_output) == (2048, 4096, 30, 20)
    assert agg.other_metrics == {"time in aggregation build": 30}  # the time_ms breakdown
    scan = [n for n in nodes if n.table_name == "main.sales.orders"][0]
    # only successful tasks count; the failed task's 7777 rows do not
    assert (scan.rows_output, scan.files_read, scan.bytes_read) == (1000, 12, 11000)
    assert by_name["Exchange"].shuffle_write_bytes == 512


def test_failures(spark, logs):
    got = {(r.level, r.cause, r.occurrences) for r in rows(spark, "classic_failures")}
    assert ("task", "SHUFFLE_FETCH_FAILED", 1) in got
    assert ("task", "OUT_OF_MEMORY_EXECUTOR", 1) in got
    assert ("task", "USER_CODE_ERROR", 1) in got
    assert ("executor", "EXECUTOR_LOST_SPOT", 1) in got
    assert ("driver", "OUT_OF_MEMORY_DRIVER", 1) in got
    assert not any(c == "CANCELLED" for _, c, _ in got)  # the speculative kill is not a failure
    assert not any(r.message_template and "killed by driver" in r.message_template
                   for r in rows(spark, "classic_failures"))
    task_oom = [r for r in rows(spark, "classic_failures") if r.cause == "OUT_OF_MEMORY_EXECUTOR"][0]
    assert (task_oom.job_id, task_oom.task_run_id) == ("111", "222")
    assert task_oom.exception_class == "java.lang.OutOfMemoryError"


def all_strings(spark):
    tables = [t.name for t in spark.catalog.listTables(SCHEMA)]
    for t in tables:
        for r in spark.table(f"{SCHEMA}.{t}").toJSON().collect():
            yield t, r


def test_privacy(spark, logs):
    for table, row in all_strings(spark):
        for marker in ("SECRET", "PRIVATE", "example.com", "bob@", "hello", "/Workspace"):
            assert marker not in row, (table, marker)


def test_rerun_changes_nothing(spark, logs):
    root, _ = logs
    before = {t: sorted(r.asDict().__repr__() for r in rows(spark, t)) for t in job.OUTPUT_TABLES}
    job.run(spark, [str(root)], SCHEMA, "all", slow_seconds=3600)
    # Forget the file state: every file is read again, the tables still don't change.
    spark.sql(f"DELETE FROM {SCHEMA}._classic_file_state")
    job.run(spark, [str(root)], SCHEMA, "all", slow_seconds=3600)
    after = {t: sorted(r.asDict().__repr__() for r in rows(spark, t)) for t in job.OUTPUT_TABLES}
    assert before == after


def test_growing_file_is_reread_without_double_counting(spark, logs):
    root, active = logs
    s0_before = statement(spark, 0)
    syn.append(active, syn.finish_open_execution())
    job.run(spark, [str(root)], SCHEMA, "all", slow_seconds=3600)
    assert statement(spark, 2).execution_status == "FINISHED"
    s0 = statement(spark, 0)
    assert (s0.task_count, s0.shuffle_read_bytes) == (s0_before.task_count, s0_before.shuffle_read_bytes)


def test_statement_without_end_fails_once_app_is_idle(spark, tmp_path):
    from tests.synthetic import append
    root = tmp_path / "logs2"
    active = syn.write_cluster(str(root))
    append(active, [syn.exec_start(3, syn.T0 + 20_000, syn.node("Project", []))])
    schema = "classic_idle"
    spark.sql(f"DROP DATABASE IF EXISTS {schema} CASCADE")
    spark.sql(f"CREATE DATABASE {schema}")
    job.run(spark, [str(root)], schema, "all", slow_seconds=3600, now=FUTURE)
    r = spark.sql(f"SELECT execution_status, end_time FROM {schema}.classic_statement_history "
                  "WHERE execution_id = 3").first()
    assert r.execution_status == "FAILED" and r.end_time is None


def test_cluster_filter(spark, tmp_path):
    root = tmp_path / "logs3"
    syn.write_cluster(str(root))
    schema = "classic_filter"
    spark.sql(f"DROP DATABASE IF EXISTS {schema} CASCADE")
    spark.sql(f"CREATE DATABASE {schema}")
    job.run(spark, [str(root)], schema, "ids:some-other-cluster", slow_seconds=3600)
    assert not spark.catalog.tableExists(f"{schema}.classic_statement_history")
