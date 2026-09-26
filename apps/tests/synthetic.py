"""Hand-written Spark event log lines, shaped like the real ones but with made-up content.

The SECRET/PRIVATE markers must never reach a table; test_privacy checks that.
"""
import json
import os

SQL = "org.apache.spark.sql.execution.ui."
T0 = 1_790_000_000_000
CLUSTER = "0926-000000-abcd1234"
APP_DIR = "0926-000000-abcd1234_10_0_0_1/1234567890"


def line(event, **fields):
    return json.dumps({"Event": event, **fields})


def metric(name, acc, mtype="sum"):
    return {"name": name, "accumulatorId": acc, "metricType": mtype}


def node(name, children=(), metrics=(), simple=None):
    return {
        "nodeName": name,
        "simpleString": simple or f"{name} PRIVATE_LITERAL 'bob@example.com'",
        "children": list(children),
        "metadata": {},
        "metrics": list(metrics),
    }


def scan(table, rows_acc, files_acc=None, size_acc=None):
    m = [metric("number of output rows", rows_acc)]
    if files_acc:
        m += [metric("number of files read", files_acc), metric("size of files read", size_acc, "size")]
    return node(f"Scan parquet {table}", metrics=m)


def initial_plan():
    join = node("SortMergeJoin", [scan("main.sales.orders", 1), scan("main.sales.customers", 4)],
                simple="SortMergeJoin [id#1], [id#9], Inner, (amount#3 > 100)")
    return node("AdaptiveSparkPlan", [node("HashAggregate", [node("Exchange", [join])])])


def final_plan():
    join = node(
        "BroadcastHashJoin",
        [scan("main.sales.orders", 1, 2, 3), node("BroadcastExchange", [scan("main.sales.customers", 4)])],
        metrics=[metric("number of output rows", 5)],
        simple="BroadcastHashJoin [id#1], [id#9], Inner, BuildRight, false",
    )
    agg = node("HashAggregate", [node("Exchange", [join], [metric("shuffle bytes written", 8, "size")])],
               [metric("spill size", 6, "size"), metric("peak memory", 7, "size"),
                metric("time in aggregation build", 9, "timing"), metric("number of output rows", 10)])
    return node("AdaptiveSparkPlan", [agg])


def exec_start(eid, t, plan):
    return line(SQL + "SparkListenerSQLExecutionStart", executionId=eid, rootExecutionId=eid,
                description="SELECT * FROM orders WHERE email = 'PRIVATE_EMAIL@example.com'",
                details="PRIVATE_DETAILS", physicalPlanDescription="== PRIVATE_PLAN_TEXT ==",
                sparkPlanInfo=plan, time=t, modifiedConfigs={"spark.secret": "SECRET-conf"})


def aqe_update(eid, plan):
    return line(SQL + "SparkListenerSQLAdaptiveExecutionUpdate", executionId=eid,
                physicalPlanDescription="PRIVATE_PLAN_TEXT", sparkPlanInfo=plan)


def exec_end(eid, t, error=None):
    fields = {"executionId": eid, "time": t}
    if error:
        fields["errorMessage"] = error
    return line(SQL + "SparkListenerSQLExecutionEnd", **fields)


def job_start(job, eid, stages, t, cluster_name="job-111-run-222"):
    return line("SparkListenerJobStart", **{
        "Job ID": job, "Submission Time": t, "Stage Infos": [], "Stage IDs": stages,
        "Properties": {
            "spark.sql.execution.id": str(eid),
            "spark.databricks.job.id": "111",
            "spark.databricks.job.runId": "222",
            "spark.databricks.job.parentRunId": "333",
            "spark.databricks.clusterUsageTags.clusterName": cluster_name,
            "spark.databricks.clusterUsageTags.orgId": "9876543210",
            "spark.hadoop.fs.secret.key": "SECRET-props",
            "spark.job.description": "PRIVATE_DESCRIPTION",
        },
    })


def job_end(job, t, failed_message=None):
    result = {"Result": "JobSucceeded"}
    if failed_message:
        result = {"Result": "JobFailed", "Exception": {"Message": failed_message, "Stack Trace": []}}
    return line("SparkListenerJobEnd", **{"Job ID": job, "Completion Time": t, "Job Result": result})


def task_end(stage, t, run_ms, reason=None, accums=(), spill=0, shuffle_read=0, shuffle_write=0, in_bytes=0):
    return line("SparkListenerTaskEnd", **{
        "Stage ID": stage, "Stage Attempt ID": 0, "Task Type": "ResultTask",
        "Task End Reason": reason or {"Reason": "Success"},
        "Task Info": {
            "Task ID": t, "Launch Time": T0 + t, "Finish Time": T0 + t + run_ms, "Failed": reason is not None,
            "Killed": False,
            "Accumulables": [{"ID": a, "Name": n, "Update": str(v), "Value": str(v), "Internal": False,
                              "Count Failed Values": False} for a, n, v in accums]
            + [{"ID": 900, "Name": "internal.metrics.executorRunTime", "Update": run_ms, "Value": run_ms,
                "Internal": True, "Count Failed Values": True}],
        },
        "Task Metrics": {
            "Executor Run Time": run_ms, "Executor CPU Time": run_ms * 1_000_000, "JVM GC Time": 5,
            "Peak Execution Memory": 1000, "Memory Bytes Spilled": spill * 2, "Disk Bytes Spilled": spill,
            "Shuffle Read Metrics": {"Remote Bytes Read": shuffle_read, "Local Bytes Read": 1,
                                     "Fetch Wait Time": 1, "Total Records Read": 10},
            "Shuffle Write Metrics": {"Shuffle Bytes Written": shuffle_write, "Shuffle Write Time": 1,
                                      "Shuffle Records Written": 10},
            "Input Metrics": {"Bytes Read": in_bytes, "Records Read": 100},
            "Output Metrics": {"Bytes Written": 0, "Records Written": 0},
        },
    })


def stage_done(stage, t, failure=None):
    info = {"Stage ID": stage, "Stage Attempt ID": 0, "Number of Tasks": 3, "Completion Time": t}
    if failure:
        info["Failure Reason"] = failure
    return line("SparkListenerStageCompleted", **{"Stage Info": info})


FETCH_FAILED = {"Reason": "FetchFailed", "Block Manager Address": {"Executor ID": "3"},
                "Message": "Failed to connect to /10.1.2.3:4048"}
OOM = {"Reason": "ExceptionFailure", "Class Name": "java.lang.OutOfMemoryError", "Description": "Java heap space",
       "Stack Trace": [], "Full Stack Trace": "PRIVATE_STACK"}
USER_ERROR = {"Reason": "ExceptionFailure", "Class Name": "org.apache.spark.api.python.PythonException",
              "Description": "ValueError: bad value 42 for PRIVATE_EMAIL@example.com", "Full Stack Trace": ""}
SPECULATIVE_KILL = {"Reason": "TaskKilled", "Kill Reason": "another attempt succeeded"}


def first_file():
    """App start, execution 0 up to its first stage."""
    return [
        line("SparkListenerLogStart", **{"Spark Version": "3.5.0"}),
        line("SparkListenerEnvironmentUpdate", **{"Spark Properties": [["spark.secret.token", "SECRET-env"]]}),
        line("SparkListenerApplicationStart", **{"App Name": "Databricks Shell", "App ID": "app-1", "Timestamp": T0}),
        exec_start(0, T0 + 10, initial_plan()),
        job_start(0, 0, [0, 1], T0 + 20),
        task_end(0, 1, 100, accums=[(1, "number of output rows", 50), (3, "size of files read", 1000)], in_bytes=1000),
        task_end(0, 2, 200, accums=[(1, "number of output rows", 50), (3, "size of files read", 1000)], in_bytes=1000),
        task_end(0, 3, 4000, accums=[(1, "number of output rows", 900), (3, "size of files read", 9000)], in_bytes=9000),
        task_end(0, 4, 50, reason=FETCH_FAILED, accums=[(1, "number of output rows", 7777)]),
        task_end(0, 5, 60, reason=SPECULATIVE_KILL),
        stage_done(0, T0 + 5000),
        "{\"Event\":\"SparkListenerTaskEnd\", \"truncated",  # a torn last line
    ]


def active_file():
    """The rest of execution 0, a failed execution 1, lost executors, an open execution 2."""
    return [
        aqe_update(0, final_plan()),
        task_end(1, 6, 300, accums=[(5, "number of output rows", 400), (6, "spill size", 2048),
                                    (7, "peak memory", 4096), (8, "shuffle bytes written", 512),
                                    (9, "time in aggregation build", 30), (10, "number of output rows", 10)],
                 spill=2048, shuffle_read=500, shuffle_write=512),
        task_end(1, 7, 300, accums=[(5, "number of output rows", 600), (10, "number of output rows", 10)],
                 shuffle_read=500, shuffle_write=512),
        task_end(1, 8, 70, reason=OOM),
        stage_done(1, T0 + 9000),
        job_end(0, T0 + 9000),
        line(SQL + "SparkListenerDriverAccumUpdates", executionId=0, accumUpdates=[[2, 12]]),
        exec_end(0, T0 + 9100),
        exec_start(1, T0 + 10_000, node("Project", [scan("main.sales.orders", 20)])),
        job_start(1, 1, [2], T0 + 10_010),
        task_end(2, 9, 10, reason=USER_ERROR),
        stage_done(2, T0 + 10_100, failure="Job aborted due to stage failure: ValueError: bad value 42\nstack"),
        job_end(1, T0 + 10_100, failed_message="Job aborted: ValueError: bad value 42\nPRIVATE_STACK"),
        exec_end(1, T0 + 10_200, error="ValueError: bad value 42 in '/Workspace/Users/PRIVATE_EMAIL@example.com/x'"),
        line("SparkListenerExecutorRemoved", **{"Timestamp": T0 + 11_000, "Executor ID": "3",
                                                "Removed Reason": "worker lost: spot instance preempted"}),
        line("SparkListenerExecutorRemoved", **{"Timestamp": T0 + 11_000, "Executor ID": "4",
                                                "Removed Reason": "Executor killed by driver."}),
        exec_start(2, T0 + 12_000, node("Project", [scan("main.sales.orders", 30)])),
    ]


def finish_open_execution():
    """Lines appended later to the active file: execution 2 ends and the app stops."""
    return [
        job_start(2, 2, [3], T0 + 12_010),
        task_end(3, 10, 20, accums=[(30, "number of output rows", 5)]),
        stage_done(3, T0 + 12_100),
        job_end(2, T0 + 12_100),
        exec_end(2, T0 + 12_200),
        line("SparkListenerApplicationEnd", Timestamp=T0 + 13_000),
    ]


STDERR = """Traceback (most recent call last):
  File "/Workspace/Users/PRIVATE_EMAIL@example.com/nb.py", line 3, in <module>
    df.write.saveAsTable("x")
py4j.protocol.Py4JJavaError: An error occurred while calling o123.saveAsTable.
: org.apache.spark.SparkException: Job aborted due to stage failure: Task 3 failed 4 times
PRIVATE_PRINT_OUTPUT hello 123
"""
LOG4J = """26/09/25 10:00:01 INFO DriverCorral: PRIVATE_INFO_LINE token=SECRET-log
26/09/25 10:00:02 ERROR Utils: Uncaught exception in thread driver-heartbeater
java.lang.OutOfMemoryError: Java heap space
\tat java.util.Arrays.copyOf(Arrays.java:3236)
"""


def write_cluster(root):
    """Write one cluster's log folder; returns the path of the active event log file."""
    ev_dir = os.path.join(root, CLUSTER, "eventlog", APP_DIR)
    os.makedirs(ev_dir)
    _write(os.path.join(ev_dir, "eventlog-2026-09-25--10-00"), first_file())
    active = os.path.join(ev_dir, "eventlog")
    _write(active, active_file())
    driver = os.path.join(root, CLUSTER, "driver")
    os.makedirs(driver)
    with open(os.path.join(driver, "stderr"), "w") as f:
        f.write(STDERR)
    with open(os.path.join(driver, "log4j-active.log"), "w") as f:
        f.write(LOG4J)
    with open(os.path.join(driver, "stdout"), "w") as f:
        f.write("PRIVATE_STDOUT SECRET-stdout\n")
    return active


def _write(path, lines):
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def append(path, lines):
    with open(path, "a") as f:
        f.write("\n".join(lines) + "\n")
