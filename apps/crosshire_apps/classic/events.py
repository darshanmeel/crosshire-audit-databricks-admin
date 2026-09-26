"""Raw cluster log files -> small per-file partial aggregates.

Everything here is keyed by the source file `path`, so re-reading a file that grew only
replaces that file's partial rows. Nothing below keeps a raw line, SQL text or a config value.
"""
from pyspark.sql import functions as F
from pyspark.sql import types as T

from crosshire_apps.classic.causes import describe, exception_from_line
from crosshire_apps.classic.plan import parse_plan

NEEDED_EVENTS = [
    "SparkListenerSQLExecutionStart",
    "SparkListenerSQLAdaptiveExecutionUpdate",
    "SparkListenerSQLExecutionEnd",
    "SparkListenerDriverAccumUpdates",
    "SparkListenerJobStart",
    "SparkListenerJobEnd",
    "SparkListenerStageCompleted",
    "SparkListenerTaskEnd",
    "SparkListenerExecutorRemoved",
    "SparkListenerApplicationEnd",
]

# Only these JobStart properties are kept; the rest can hold config values or secrets.
JOB_PROPERTIES = [
    "spark.sql.execution.id",
    "spark.databricks.job.id",
    "spark.databricks.job.runId",
    "spark.databricks.job.parentRunId",
    "spark.databricks.job.taskKey",
    "spark.databricks.clusterUsageTags.clusterName",
    "spark.databricks.clusterUsageTags.orgId",
]

# Executor removals that are normal scale-down, not failures (to confirm on real logs).
BENIGN_EXECUTOR_REMOVAL = r"(?i)killed by driver|autoscal|downscal|scale down|idle"
# A speculative copy killed because another attempt won is not a failure.
BENIGN_TASK_KILL = r"(?i)another attempt succeeded"

# Task run time histogram: 4 buckets per doubling, so p50/p95 are within ~9%.
HIST_BUCKETS_PER_DOUBLING = 4


def normalise_path(col):
    """One spelling per file, whether it came from the listing or from _metadata.file_path."""
    return F.regexp_replace(col, "^dbfs:", "")


def decoded_path(col):
    """_metadata.file_path is URL-encoded; the file listing is not. '+' must stay a '+'."""
    return normalise_path(F.url_decode(F.regexp_replace(col, r"\+", "%2B")))


def with_ids(df):
    """cluster_id, app_id and group_key from the path <root>/<cluster_id>/eventlog/.../<app dir>/<file>."""
    app_dir = F.regexp_extract("path", r"^(.*)/[^/]+$", 1)
    return (
        df.withColumn("cluster_id", F.regexp_extract("path", r"/([^/]+)/eventlog/", 1))
        .withColumn("app_id", F.regexp_extract(app_dir, r"([^/]+)$", 1))
        .withColumn("group_key", F.concat_ws("/", "cluster_id", "app_id"))
    )


def read_events(spark, paths):
    """Needed events only, with path, ids, a file order key and a line order key."""
    lines = spark.read.text(paths).select(
        "value",
        decoded_path(F.col("_metadata.file_path")).alias("path"),
        F.monotonically_increasing_id().alias("line_id"),
    )
    lines = lines.withColumn("event", F.substring_index(F.get_json_object("value", "$.Event"), ".", -1))
    lines = lines.where(F.col("event").isin(NEEDED_EVENTS))
    name = F.regexp_extract("path", r"([^/]+)$", 1)
    # The active file is plain "eventlog" and holds the newest events; rolled files sort by date.
    lines = lines.withColumn("file_key", F.when(name == "eventlog", F.lit("eventlog~")).otherwise(name))
    return with_ids(lines)


def _j(path, cast=None):
    c = F.get_json_object("value", path)
    return c.cast(cast) if cast else c


def _ms_to_ts(c):
    return F.timestamp_millis(c.cast("long"))


_NODE = T.StructType([
    T.StructField("node_id", T.IntegerType()),
    T.StructField("parent_node_id", T.IntegerType()),
    T.StructField("node_name", T.StringType()),
    T.StructField("join_type", T.StringType()),
    T.StructField("table_name", T.StringType()),
    T.StructField("is_write", T.BooleanType()),
    T.StructField("metrics", T.ArrayType(T.StructType([
        T.StructField("name", T.StringType()),
        T.StructField("accumulator_id", T.LongType()),
        T.StructField("metric_type", T.StringType()),
    ]))),
])
_PLAN = T.StructType([T.StructField("plan_hash", T.StringType()), T.StructField("nodes", T.ArrayType(_NODE))])


@F.udf(_PLAN)
def _parse_plan_udf(plan_json):
    h, nodes = parse_plan(plan_json)
    return h, [{k: n[k] for k in _NODE.fieldNames()} for n in nodes]


def plans(ev):
    """One row per plan event; the last one per execution (AQE final plan) wins later."""
    df = ev.where(F.col("event").isin("SparkListenerSQLExecutionStart", "SparkListenerSQLAdaptiveExecutionUpdate"))
    df = df.select(
        "path", "group_key", "cluster_id", "app_id", "file_key", "line_id",
        _j("$.executionId", "long").alias("execution_id"),
        _parse_plan_udf(_j("$.sparkPlanInfo")).alias("plan"),
    )
    return df.select("*", "plan.plan_hash", "plan.nodes").drop("plan")


_FP = T.StructType([
    T.StructField("cause", T.StringType()),
    T.StructField("message_fingerprint", T.StringType()),
    T.StructField("message_template", T.StringType()),
])


@F.udf(_FP)
def _describe_udf(level, exception_class, message):
    return describe(level, exception_class, message)


def executions(ev):
    """Start, end and error fingerprint per execution and file."""
    start = ev.where(F.col("event") == "SparkListenerSQLExecutionStart")
    end = ev.where(F.col("event") == "SparkListenerSQLExecutionEnd")
    rows = start.select(
        "path", "group_key", "cluster_id", "app_id",
        _j("$.executionId", "long").alias("execution_id"),
        _ms_to_ts(_j("$.time")).alias("start_time"),
        F.lit(None).cast("timestamp").alias("end_time"),
        F.lit(None).cast("string").alias("error_message"),
    ).unionByName(end.select(
        "path", "group_key", "cluster_id", "app_id",
        _j("$.executionId", "long").alias("execution_id"),
        F.lit(None).cast("timestamp").alias("start_time"),
        _ms_to_ts(_j("$.time")).alias("end_time"),
        F.when(_j("$.errorMessage") != "", _j("$.errorMessage")).alias("error_message"),
    ))
    rows = rows.withColumn("error_fingerprint", _describe_udf(F.lit("statement"), F.lit(None), "error_message")
                           .getField("message_fingerprint")).drop("error_message")
    return rows.groupBy("path", "group_key", "cluster_id", "app_id", "execution_id").agg(
        F.min("start_time").alias("start_time"),
        F.max("end_time").alias("end_time"),
        F.max("error_fingerprint").alias("error_fingerprint"),
    )


_ACCUM = T.ArrayType(T.StructType([
    T.StructField("ID", T.LongType()),
    T.StructField("Name", T.StringType()),
    T.StructField("Update", T.StringType()),
]))


def accumulators(ev):
    """Summed SQL metric updates per accumulator: successful tasks plus driver-side updates."""
    tasks = ev.where(
        (F.col("event") == "SparkListenerTaskEnd") & (_j("$['Task End Reason'].Reason") == "Success")
    ).select(
        "path", "group_key", "cluster_id", "app_id",
        F.explode(F.from_json(_j("$['Task Info'].Accumulables"), _ACCUM)).alias("a"),
    ).where(~F.coalesce(F.col("a.Name"), F.lit("")).startswith("internal.")).select(
        "path", "group_key", "cluster_id", "app_id",
        F.col("a.ID").alias("accumulator_id"),
        F.col("a.Update").cast("long").alias("value"),
    )
    driver = ev.where(F.col("event") == "SparkListenerDriverAccumUpdates").select(
        "path", "group_key", "cluster_id", "app_id",
        F.explode(F.from_json(_j("$.accumUpdates"), T.ArrayType(T.ArrayType(T.LongType())))).alias("u"),
    ).select(
        "path", "group_key", "cluster_id", "app_id",
        F.col("u")[0].alias("accumulator_id"), F.col("u")[1].alias("value"),
    )
    # Size and timing metrics start at -1 in Spark; a negative update means "not set".
    return tasks.unionByName(driver).where(F.col("value") > 0).groupBy(
        "path", "group_key", "cluster_id", "app_id", "accumulator_id"
    ).agg(F.sum("value").alias("value"))


def jobs(ev):
    """Job -> execution and stage ids, the kept properties, and the job result, per file."""
    start = ev.where(F.col("event") == "SparkListenerJobStart").select(
        "path", "group_key", "cluster_id", "app_id",
        _j("$['Job ID']", "long").alias("job_id"),
        F.from_json(_j("$['Stage IDs']"), T.ArrayType(T.LongType())).alias("stage_ids"),
        F.from_json(_j("$.Properties"), T.MapType(T.StringType(), T.StringType())).alias("props"),
        F.lit(None).cast("string").alias("result"),
        F.lit(None).cast("string").alias("error_message"),
        _ms_to_ts(_j("$['Submission Time']")).alias("event_time"),
    )
    start = start.withColumn("props", F.map_filter("props", lambda k, v: k.isin(JOB_PROPERTIES)))
    end = ev.where(F.col("event") == "SparkListenerJobEnd").select(
        "path", "group_key", "cluster_id", "app_id",
        _j("$['Job ID']", "long").alias("job_id"),
        F.lit(None).cast("array<long>").alias("stage_ids"),
        F.lit(None).cast("map<string,string>").alias("props"),
        _j("$['Job Result'].Result").alias("result"),
        _j("$['Job Result'].Exception.Message").alias("error_message"),
        _ms_to_ts(_j("$['Completion Time']")).alias("event_time"),
    )
    return start.unionByName(end).drop("error_message")


def _hist_bucket(ms):
    return F.floor(F.log2(ms + 1) * HIST_BUCKETS_PER_DOUBLING).cast("int")


def stages(ev):
    """Task metrics summed per stage attempt and file; task rows are never kept."""
    t = ev.where(F.col("event") == "SparkListenerTaskEnd").select(
        "path", "group_key", "cluster_id", "app_id",
        _j("$['Stage ID']", "long").alias("stage_id"),
        _j("$['Stage Attempt ID']", "int").alias("stage_attempt_id"),
        (_j("$['Task End Reason'].Reason") == "Success").alias("ok"),
        _j("$['Task Metrics']['Executor Run Time']", "long").alias("run_ms"),
        _j("$['Task Metrics']['Executor CPU Time']", "long").alias("cpu_ns"),
        _j("$['Task Metrics']['JVM GC Time']", "long").alias("gc_ms"),
        _j("$['Task Metrics']['Peak Execution Memory']", "long").alias("peak_mem"),
        _j("$['Task Metrics']['Memory Bytes Spilled']", "long").alias("mem_spill"),
        _j("$['Task Metrics']['Disk Bytes Spilled']", "long").alias("disk_spill"),
        _j("$['Task Metrics']['Shuffle Read Metrics']['Remote Bytes Read']", "long").alias("sr_remote"),
        _j("$['Task Metrics']['Shuffle Read Metrics']['Local Bytes Read']", "long").alias("sr_local"),
        _j("$['Task Metrics']['Shuffle Read Metrics']['Fetch Wait Time']", "long").alias("fetch_wait"),
        _j("$['Task Metrics']['Shuffle Read Metrics']['Total Records Read']", "long").alias("sr_records"),
        _j("$['Task Metrics']['Shuffle Write Metrics']['Shuffle Bytes Written']", "long").alias("sw_bytes"),
        _j("$['Task Metrics']['Shuffle Write Metrics']['Shuffle Records Written']", "long").alias("sw_records"),
        _j("$['Task Metrics']['Input Metrics']['Bytes Read']", "long").alias("in_bytes"),
        _j("$['Task Metrics']['Input Metrics']['Records Read']", "long").alias("in_records"),
        _j("$['Task Metrics']['Output Metrics']['Bytes Written']", "long").alias("out_bytes"),
        _j("$['Task Metrics']['Output Metrics']['Records Written']", "long").alias("out_records"),
    )
    keys = ["path", "group_key", "cluster_id", "app_id", "stage_id", "stage_attempt_id"]
    # Totals include failed tasks' metrics, as the Spark UI stage table does.
    totals = t.groupBy(*keys).agg(
        F.count("*").alias("task_count"),
        F.sum(F.when(~F.col("ok"), 1).otherwise(0)).alias("failed_task_count"),
        F.sum("run_ms").alias("task_run_ms"),
        F.sum("cpu_ns").alias("task_cpu_ns"),
        F.sum("gc_ms").alias("gc_time_ms"),
        F.max("peak_mem").alias("max_peak_memory_bytes"),
        F.sum("mem_spill").alias("memory_spilled_bytes"),
        F.sum("disk_spill").alias("disk_spilled_bytes"),
        F.sum(F.col("sr_remote") + F.col("sr_local")).alias("shuffle_read_bytes"),
        F.sum("sr_remote").alias("shuffle_remote_read_bytes"),
        F.sum("fetch_wait").alias("shuffle_fetch_wait_ms"),
        F.sum("sr_records").alias("shuffle_read_records"),
        F.sum("sw_bytes").alias("shuffle_write_bytes"),
        F.sum("sw_records").alias("shuffle_write_records"),
        F.sum("in_bytes").alias("input_bytes"),
        F.sum("in_records").alias("input_records"),
        F.sum("out_bytes").alias("output_bytes"),
        F.sum("out_records").alias("output_records"),
        F.max(F.when(F.col("ok"), F.col("run_ms"))).alias("max_task_ms"),
    )
    # The UI's percentiles use successful tasks only.
    hist = (
        t.where("ok AND run_ms IS NOT NULL")
        .groupBy(*keys, _hist_bucket(F.col("run_ms")).alias("b"))
        .agg(F.count("*").alias("n"))
        .groupBy(*keys)
        .agg(F.map_from_entries(F.collect_list(F.struct("b", "n"))).alias("run_ms_hist"))
    )
    return totals.join(hist, keys, "left")


def failures(ev):
    """Distinct failures per file: failed tasks, failed stages, failed jobs, lost executors."""
    base = ["path", "group_key", "cluster_id", "app_id"]
    task = ev.where(
        (F.col("event") == "SparkListenerTaskEnd")
        & ~_j("$['Task End Reason'].Reason").isin("Success", "Resubmitted", "TaskCommitDenied")
    ).select(
        *base,
        F.lit("task").alias("level"),
        _j("$['Stage ID']", "long").alias("stage_id"),
        F.lit(None).cast("long").alias("job_id"),
        F.coalesce(_j("$['Task End Reason']['Class Name']"), _j("$['Task End Reason'].Reason")).alias("exception_class"),
        F.coalesce(
            _j("$['Task End Reason'].Description"),
            _j("$['Task End Reason']['Loss Reason']"),
            _j("$['Task End Reason']['Kill Reason']"),
            _j("$['Task End Reason'].Message"),
        ).alias("message"),
        _ms_to_ts(_j("$['Task Info']['Finish Time']")).alias("seen_at"),
    ).where(~F.coalesce(F.col("message"), F.lit("")).rlike(BENIGN_TASK_KILL))
    stage = ev.where(
        (F.col("event") == "SparkListenerStageCompleted") & _j("$['Stage Info']['Failure Reason']").isNotNull()
    ).select(
        *base,
        F.lit("stage").alias("level"),
        _j("$['Stage Info']['Stage ID']", "long").alias("stage_id"),
        F.lit(None).cast("long").alias("job_id"),
        F.regexp_extract(_j("$['Stage Info']['Failure Reason']"), r"([\w.$]+(?:Exception|Error))", 1).alias("exception_class"),
        # Keep the first line only: the rest is a stack trace.
        F.substring_index(_j("$['Stage Info']['Failure Reason']"), "\n", 1).alias("message"),
        _ms_to_ts(_j("$['Stage Info']['Completion Time']")).alias("seen_at"),
    )
    job = ev.where(
        (F.col("event") == "SparkListenerJobEnd") & (_j("$['Job Result'].Result") == "JobFailed")
    ).select(
        *base,
        F.lit("job").alias("level"),
        F.lit(None).cast("long").alias("stage_id"),
        _j("$['Job ID']", "long").alias("job_id"),
        F.regexp_extract(_j("$['Job Result'].Exception.Message"), r"([\w.$]+(?:Exception|Error))", 1).alias("exception_class"),
        F.substring_index(_j("$['Job Result'].Exception.Message"), "\n", 1).alias("message"),
        _ms_to_ts(_j("$['Completion Time']")).alias("seen_at"),
    )
    executor = ev.where(
        (F.col("event") == "SparkListenerExecutorRemoved")
        & ~F.coalesce(_j("$['Removed Reason']"), F.lit("")).rlike(BENIGN_EXECUTOR_REMOVAL)
    ).select(
        *base,
        F.lit("executor").alias("level"),
        F.lit(None).cast("long").alias("stage_id"),
        F.lit(None).cast("long").alias("job_id"),
        F.lit("ExecutorRemoved").alias("exception_class"),
        _j("$['Removed Reason']").alias("message"),
        _ms_to_ts(_j("$.Timestamp")).alias("seen_at"),
    )
    rows = task.unionByName(stage).unionByName(job).unionByName(executor)
    return summarise_failures(rows, base + ["stage_id", "job_id"])


def summarise_failures(rows, keys):
    rows = rows.withColumn("exception_class", F.when(F.col("exception_class") != "", F.col("exception_class")))
    rows = rows.withColumn("d", _describe_udf("level", "exception_class", "message")).drop("message")
    rows = rows.select("*", "d.cause", "d.message_fingerprint", "d.message_template").drop("d")
    return rows.groupBy(*keys, "level", "cause", "exception_class", "message_fingerprint").agg(
        F.first("message_template", ignorenulls=True).alias("message_template"),
        F.count("*").alias("occurrences"),
        F.min("seen_at").alias("first_seen"),
        F.max("seen_at").alias("last_seen"),
    )


def app_ends(ev):
    return ev.where(F.col("event") == "SparkListenerApplicationEnd").select(
        "path", "group_key", "cluster_id", "app_id", _ms_to_ts(_j("$.Timestamp")).alias("app_end_time")
    )


@F.udf(T.StructType([T.StructField("cls", T.StringType()), T.StructField("msg", T.StringType())]))
def _exception_udf(line):
    return exception_from_line(line)


def text_log_failures(spark, paths):
    """Exception lines from driver/executor stderr and log4j files; every other line is dropped.

    Text logs belong to a cluster, not an app, so they are grouped by cluster and day.
    """
    lines = spark.read.text(paths).select(
        "value",
        decoded_path(F.col("_metadata.file_path")).alias("path"),
        F.col("_metadata.file_modification_time").alias("seen_at"),
    )
    # Cheap pre-filter before the Python regex.
    lines = lines.where(F.col("value").rlike(r"(Error|Exception|Exit)\b"))
    lines = lines.withColumn("e", _exception_udf("value")).where(F.col("e").isNotNull())
    lines = lines.select(
        "path",
        F.regexp_extract("path", r"/([^/]+)/(?:driver|executor)/", 1).alias("cluster_id"),
        F.regexp_extract("path", r"/(driver|executor)/", 1).alias("level"),
        F.col("e.cls").alias("exception_class"),
        F.col("e.msg").alias("message"),
        "seen_at",
    )
    lines = lines.withColumn("app_id", F.lit(None).cast("string")).withColumn(
        "group_key", F.concat_ws("/", "cluster_id", F.lit("text"), F.to_date("seen_at").cast("string"))
    ).withColumn("stage_id", F.lit(None).cast("long")).withColumn("job_id", F.lit(None).cast("long"))
    return summarise_failures(lines, ["path", "group_key", "cluster_id", "app_id", "stage_id", "job_id"])
