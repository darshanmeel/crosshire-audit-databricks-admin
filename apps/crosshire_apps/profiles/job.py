"""Daily job: fetch the query profiles of selected SQL warehouse and serverless statements.

1. Pick yesterday's statements from query history: failed, spilled, slower than
   --slow-seconds, and the top --top-n by task time, per workspace and compute. At most --cap,
   skipping statements that already have a profile.
2. Fetch each profile by replaying the request the UI makes (captured once, see
   PROBE_GUIDE.md) with a token, a few at a time, backing off on 429 and 5xx.
3. Parse it in memory and MERGE `query_profile_nodes`, `query_profile_summary` and
   `query_profile_fetch_log`. The raw JSON (which holds the SQL text) is never stored.

    DATABRICKS_TOKEN=... python -m crosshire_apps.profiles.job --request-file request.txt \
        --output main.crosshire_audit --slow-seconds 300 --top-n 50 --cap 500
"""
import argparse
import datetime as dt
import json
import os
import re
import time
from concurrent.futures import ThreadPoolExecutor

from pyspark.sql import SparkSession, Window
from pyspark.sql import functions as F

from crosshire_apps.common.delta_io import merge, stamp, table_size
from crosshire_apps.profiles.parser import NODE_COLUMNS, parse_profile, summarise
from crosshire_apps.profiles.probe_profile import parse_curl, probe

OUTPUT_TABLES = ["query_profile_nodes", "query_profile_summary", "query_profile_fetch_log"]
CONCURRENCY = 4
MAX_TRIES = 5
# After this many refusals in a row the token route is not working; stop asking.
STOP_AFTER_REFUSALS = 5


def parse_args(argv=None):
    a = argparse.ArgumentParser()
    a.add_argument("--request-file", required=True, help="the UI's profile request as cURL, cookies removed")
    a.add_argument("--output", required=True, help="catalog.schema for the tables")
    a.add_argument("--slow-seconds", required=True, type=int)
    a.add_argument("--top-n", required=True, type=int, help="top N by task time per workspace and compute")
    a.add_argument("--cap", required=True, type=int, help="at most this many profiles per day")
    args = a.parse_args(argv)
    if not re.fullmatch(r"[\w-]+\.[\w-]+", args.output):
        a.error("--output must be catalog.schema")
    return args


def select_statements(spark, history, schema, slow_seconds, top_n, cap, day):
    """Rows of (statement_id, workspace_id, compute_type, warehouse_id, job_task_run_id, reasons)."""
    h = history.where(F.to_date("end_time") == F.lit(day).cast("date"))
    per_compute = Window.partitionBy("workspace_id", "compute.type", "compute.warehouse_id")
    h = h.withColumn("task_rank", F.row_number().over(per_compute.orderBy(F.desc("total_task_duration_ms"))))
    reasons = F.array_compact(F.array(
        F.when(F.col("execution_status") == "FAILED", F.lit("failed")),
        F.when(F.coalesce("spilled_local_bytes", F.lit(0)) > 0, F.lit("spilled")),
        F.when(F.col("total_duration_ms") >= slow_seconds * 1000, F.lit("slow")),
        F.when(F.col("task_rank") <= top_n, F.lit("top_task_time")),
    ))
    h = h.withColumn("reasons", reasons).where(F.size("reasons") > 0)
    log = f"{schema}.query_profile_fetch_log"
    if spark.catalog.tableExists(log):
        h = h.join(spark.table(log).where("result = 'ok'").select("statement_id"), "statement_id", "left_anti")
    return h.orderBy(F.desc(F.array_contains("reasons", "failed")), F.desc("total_task_duration_ms")).limit(cap).select(
        "statement_id",
        F.col("workspace_id").cast("string").alias("workspace_id"),
        F.col("compute.type").alias("compute_type"),
        F.col("compute.warehouse_id").alias("warehouse_id"),
        F.col("query_source.job_info.job_task_run_id").cast("string").alias("job_task_run_id"),
    )


def api_source(request_text, host, token):
    """fetch(statement_id) -> (result, doc) using the captured UI request. Swap for another source."""
    method, url, headers, body = parse_curl(request_text)

    def fetch(statement_id):
        for attempt in range(MAX_TRIES):
            try:
                status, _, payload = probe(method, url, headers, body, host, token, statement_id)
            except OSError:
                status, payload = 599, b""
            if status == 429 or status >= 500:
                time.sleep(min(60, 2 ** attempt))
                continue
            if status in (401, 403):
                return "refused", None
            if status == 404:
                return "not found", None
            if status != 200:
                return f"http {status}", None
            try:
                return "ok", json.loads(payload)
            except ValueError:
                return "parse error", None
        return f"http {status} after {MAX_TRIES} tries", None

    return fetch


def fetch_all(fetch, statement_ids):
    """{statement_id: (result, doc)}; stops early once the endpoint keeps refusing."""
    out, refusals = {}, 0
    with ThreadPoolExecutor(CONCURRENCY) as pool:
        for i in range(0, len(statement_ids), CONCURRENCY):
            chunk = statement_ids[i:i + CONCURRENCY]
            for sid, res in zip(chunk, pool.map(fetch, chunk)):
                out[sid] = res
                refusals = refusals + 1 if res[0] == "refused" else 0
            if refusals >= STOP_AFTER_REFUSALS:
                print(f"stopped: {refusals} refusals in a row; the token route is not accepted")
                break
    return out


def to_rows(fetched):
    """Parsed profiles -> (node rows, summary rows, log rows). Docs are dropped after this."""
    nodes, summaries, log = [], [], []
    now = dt.datetime.now(dt.timezone.utc).replace(tzinfo=None)
    for sid, (result, doc) in fetched.items():
        parsed = None
        if result == "ok":
            try:
                parsed = parse_profile(doc)
            except Exception:  # an unexpected shape is a parse error for this statement only
                result = "parse error"
            if result == "ok" and parsed is None:
                result = "not found"  # a reply without an operator graph means no profile
        log.append({"statement_id": sid, "fetched_at": now, "result": result})
        if parsed:
            statement, node_list = parsed
            for n in node_list:
                nodes.append({"statement_id": sid, **{k: v for k, v in n.items() if k != "child_count"}})
            summaries.append({"statement_id": sid, "execution_status": statement["execution_status"],
                              "error_fingerprint": statement["error_fingerprint"],
                              "plan_hash": statement["plan_hash"], **summarise(node_list)})
    return nodes, summaries, log


_NODE_SCHEMA = (
    "statement_id string, node_id int, parent_node_id int, node_name string, node_tag string, join_type string, "
    "table_name string, is_hidden boolean, "
    + ", ".join(f"{c} bigint" for c in NODE_COLUMNS)
    + ", other_metrics map<string,bigint>"
)
_OP = "array<struct<node_id:int,node_name:string,{}>>"
_SUMMARY_SCHEMA = (
    "statement_id string, execution_status string, error_fingerprint string, plan_hash string, "
    "total_operator_time_ms bigint, "
    f"slowest_operators {_OP.format('time_ms:bigint,time_share:double')}, "
    f"spill_by_operator {_OP.format('bytes:bigint')}, "
    f"shuffle_by_operator {_OP.format('bytes:bigint')}, "
    f"join_blow_up {_OP.format('rows_in:bigint,rows_out:bigint,blow_up:double')}, "
    "scan_pruning array<struct<table_name:string,files_read:bigint,files_pruned:bigint,"
    "bytes_read:bigint,bytes_pruned:bigint>>"
)
_LOG_SCHEMA = "statement_id string, fetched_at timestamp, result string"


def run(spark, fetch, schema, slow_seconds, top_n, cap, history_table="system.query.history", day=None):
    day = day or (dt.date.today() - dt.timedelta(days=1)).isoformat()
    history = spark.table(history_table)
    chosen = select_statements(spark, history, schema, slow_seconds, top_n, cap, day).cache()
    ids = [r.statement_id for r in chosen.select("statement_id").collect()]
    print(f"statements chosen for {day}: {len(ids)}")
    if not ids:
        return
    nodes, summaries, log = to_rows(fetch_all(fetch, ids))

    context = chosen.select("statement_id", "workspace_id", "compute_type", "warehouse_id", "job_task_run_id")
    ctx = ["workspace_id", "compute_type", "warehouse_id"]
    nodes_df = spark.createDataFrame(nodes, _NODE_SCHEMA).join(context.drop("job_task_run_id"), "statement_id", "left")
    summary_df = spark.createDataFrame(summaries, _SUMMARY_SCHEMA).join(context, "statement_id", "left")
    log_df = spark.createDataFrame(log, _LOG_SCHEMA).join(context.select("statement_id", *ctx), "statement_id", "left")

    merge(spark, stamp(nodes_df), f"{schema}.query_profile_nodes", ["statement_id", "node_id"], scope="statement_id")
    merge(spark, stamp(summary_df), f"{schema}.query_profile_summary", ["statement_id"])
    merge(spark, stamp(log_df), f"{schema}.query_profile_fetch_log", ["statement_id"])

    counts = {}
    for row in log:
        counts[row["result"]] = counts.get(row["result"], 0) + 1
    print("fetch results:", counts)
    for t in OUTPUT_TABLES:
        full = f"{schema}.{t}"
        if spark.catalog.tableExists(full):
            size, n = table_size(spark, full)
            print(f"{t}: {spark.table(full).count()} rows, {size / 1e6:.2f} MB in {n} files")


def main(argv=None):
    a = parse_args(argv)
    spark = SparkSession.builder.getOrCreate()
    token = os.environ.get("DATABRICKS_TOKEN")
    host = os.environ.get("DATABRICKS_HOST") or "https://" + spark.conf.get("spark.databricks.workspaceUrl")
    if not token:
        raise SystemExit("set DATABRICKS_TOKEN (e.g. from a secret: {{secrets/<scope>/<key>}})")
    with open(a.request_file) as f:
        fetch = api_source(f.read(), host, token)
    run(spark, fetch, a.output, a.slow_seconds, a.top_n, a.cap)


if __name__ == "__main__":
    main()
