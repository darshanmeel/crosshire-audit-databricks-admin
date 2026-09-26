"""Per-file partials -> the three output tables, for the app groups touched in this run."""
from pyspark.sql import Window
from pyspark.sql import functions as F

from crosshire_apps.classic.events import HIST_BUCKETS_PER_DOUBLING
from crosshire_apps.classic.plan import COMMON_METRICS, TIMING_TYPES

# A statement with no end event counts as failed once its app is over: the app logged its end,
# or no file of the app changed for this long (a driver crash never logs an end).
APP_IDLE_HOURS = 24
_JOB_CLUSTER_NAME = r"^job-(\d+)-run-(\d+)"
_NODE_COLUMNS = sorted(set(COMMON_METRICS.values()))
_GROUP = ["group_key", "cluster_id", "app_id"]


def _statement_id():
    return F.concat_ws(":", "cluster_id", "app_id", F.col("execution_id").cast("string"))


def _links(props, prefix=""):
    """Job ids from the job properties, else from a job cluster's name."""
    name = props["spark.databricks.clusterUsageTags.clusterName"]
    from_name = F.regexp_extract(name, _JOB_CLUSTER_NAME, 1) != ""
    job_id = props["spark.databricks.job.id"]
    cols = {
        "job_id": F.coalesce(job_id, F.when(from_name, F.regexp_extract(name, _JOB_CLUSTER_NAME, 1))),
        "job_run_id": props["spark.databricks.job.parentRunId"],
        "task_run_id": F.coalesce(
            props["spark.databricks.job.runId"], F.when(from_name, F.regexp_extract(name, _JOB_CLUSTER_NAME, 2))
        ),
        "task_key": props["spark.databricks.job.taskKey"],
        "workspace_id": props["spark.databricks.clusterUsageTags.orgId"],
        "job_link_source": F.when(job_id.isNotNull(), "job_properties").when(from_name, "cluster_name"),
    }
    return [c.alias(prefix + n) for n, c in cols.items()]


def _jobs(p):
    j = p("jobs").groupBy(*_GROUP, "job_id").agg(
        F.first("stage_ids", ignorenulls=True).alias("stage_ids"),
        F.first("props", ignorenulls=True).alias("props"),
        F.max("result").alias("result"),
    )
    return j.withColumn("execution_id", F.col("props")["spark.sql.execution.id"].cast("long"))


def _percentile(hist, q):
    """Approximate task-time percentile from the merged log-scale histogram."""
    w = Window.partitionBy(*_GROUP, "stage_id").orderBy("b")
    h = hist.withColumn("cum", F.sum("n").over(w)).withColumn(
        "total", F.sum("n").over(Window.partitionBy(*_GROUP, "stage_id"))
    )
    h = h.where(F.col("cum") >= F.col("total") * q).groupBy(*_GROUP, "stage_id").agg(F.min("b").alias("b"))
    value = F.round(F.pow(F.lit(2.0), (F.col("b") + 0.5) / HIST_BUCKETS_PER_DOUBLING) - 1).cast("long")
    return h.select(*_GROUP, "stage_id", value.alias(f"p{int(q * 100)}_task_ms"))


def _stage_metrics(p, jobs):
    s = p("stages")
    sums = [c for c, _ in s.dtypes if c not in ("path", *_GROUP, "stage_id", "stage_attempt_id",
                                                  "max_peak_memory_bytes", "max_task_ms", "run_ms_hist")]
    per_stage = s.groupBy(*_GROUP, "stage_id").agg(
        *[F.sum(c).alias(c) for c in sums],
        F.max("max_peak_memory_bytes").alias("max_peak_memory_bytes"),
        F.max("max_task_ms").alias("max_task_ms"),
    )
    hist = s.select(*_GROUP, "stage_id", F.explode("run_ms_hist").alias("b", "n")).groupBy(
        *_GROUP, "stage_id", "b"
    ).agg(F.sum("n").alias("n"))
    per_stage = per_stage.join(_percentile(hist, 0.5), [*_GROUP, "stage_id"], "left").join(
        _percentile(hist, 0.95), [*_GROUP, "stage_id"], "left"
    )
    # A stage listed by several jobs (a skipped, reused stage) belongs to the first job.
    stage_exec = (
        jobs.select(*_GROUP, "job_id", "execution_id", F.explode("stage_ids").alias("stage_id"))
        .groupBy(*_GROUP, "stage_id")
        .agg(F.min_by("execution_id", "job_id").alias("execution_id"))
    )
    return per_stage.join(stage_exec, [*_GROUP, "stage_id"])


def _node_metrics(p, plans):
    nodes = plans.select(*_GROUP, "execution_id", F.explode("nodes").alias("n")).select(
        *_GROUP, "execution_id", "n.*"
    )
    accums = p("accums").groupBy(*_GROUP, "accumulator_id").agg(F.sum("value").alias("value"))
    m = nodes.select(*_GROUP, "execution_id", "node_id", F.explode("metrics").alias("m")).select(
        *_GROUP, "execution_id", "node_id", "m.*"
    ).where(F.col("metric_type") != "average")
    m = m.join(accums, [*_GROUP, "accumulator_id"])
    m = m.withColumn(
        "value", F.when(F.col("metric_type") == "nsTiming", F.col("value") / 1_000_000).otherwise(F.col("value")).cast("long")
    ).groupBy(*_GROUP, "execution_id", "node_id", "name", "metric_type").agg(F.sum("value").alias("value"))
    common = F.create_map(*[x for kv in COMMON_METRICS.items() for x in map(F.lit, kv)])
    m = m.withColumn("common", common[F.col("name")])
    per_node = m.groupBy(*_GROUP, "execution_id", "node_id").agg(
        *[F.sum(F.when(F.col("common") == c, F.col("value"))).alias(c) for c in _NODE_COLUMNS],
        F.sum(F.when(F.col("metric_type").isin(*TIMING_TYPES), F.col("value"))).alias("time_ms"),
        F.map_from_entries(
            F.array_sort(F.collect_list(F.when(F.col("common").isNull(), F.struct("name", "value"))))
        ).alias("other_metrics"),
    )
    return nodes.drop("metrics").join(per_node, [*_GROUP, "execution_id", "node_id"], "left")


def build(spark, schema, groups, files, slow_ms, now=None):
    """(statements, nodes, failures) for the given group_keys; files is the current listing."""
    now = F.current_timestamp() if now is None else F.lit(now).cast("timestamp")

    def p(name):
        return spark.table(f"{schema}._classic_partial_{name}").join(groups, "group_key", "left_semi")

    plans = p("plans").groupBy(*_GROUP, "execution_id").agg(
        F.max_by(F.struct("plan_hash", "nodes"), F.struct("file_key", "line_id")).alias("plan")
    ).select(*_GROUP, "execution_id", "plan.plan_hash", "plan.nodes")
    execs = p("execs").groupBy(*_GROUP, "execution_id").agg(
        F.min("start_time").alias("start_time"),
        F.max("end_time").alias("end_time"),
        F.max("error_fingerprint").alias("error_fingerprint"),
    )
    jobs = _jobs(p)
    stages = _stage_metrics(p, jobs)
    nodes = _node_metrics(p, plans)

    # Status inputs: job results and whether the app is over.
    job_state = jobs.groupBy(*_GROUP, "execution_id").agg(
        F.max(F.col("result") == "JobFailed").alias("job_failed"),
        F.min_by("props", "job_id").alias("props"),
    )
    last_file = files.join(groups, "group_key", "left_semi").groupBy("group_key").agg(
        F.max("modification_time").alias("last_file")
    )
    app_over = last_file.join(
        p("app_ends").select("group_key").distinct().withColumn("ended", F.lit(True)), "group_key", "left"
    ).select(
        "group_key",
        (F.coalesce("ended", F.lit(False)) | (F.col("last_file") < now - F.expr(f"INTERVAL {APP_IDLE_HOURS} HOURS")))
        .alias("app_over"),
    )
    # Any job cluster name seen in the app links statements that ran no job of their own.
    app_props = jobs.where(F.col("props").isNotNull()).groupBy("group_key").agg(
        F.min_by("props", "job_id").alias("app_props")
    )

    worst = Window.partitionBy(*_GROUP, "execution_id").orderBy(F.desc("task_run_ms"), "stage_id")
    stage_totals = stages.groupBy(*_GROUP, "execution_id").agg(
        F.count("*").alias("stage_count"),
        F.sum("task_count").alias("task_count"),
        F.sum("failed_task_count").alias("failed_task_count"),
        F.sum("task_run_ms").alias("total_task_duration_ms"),
        F.sum("gc_time_ms").alias("gc_time_ms"),
        F.sum("disk_spilled_bytes").alias("spilled_local_bytes"),
        F.sum("memory_spilled_bytes").alias("memory_spilled_bytes"),
        F.sum("shuffle_read_bytes").alias("shuffle_read_bytes"),
        F.sum("shuffle_write_bytes").alias("shuffle_write_bytes"),
        F.sum("input_bytes").alias("read_bytes"),
        F.sum("input_records").alias("read_rows"),
        F.sum("output_bytes").alias("written_bytes"),
        F.sum("output_records").alias("written_rows"),
    ).join(
        stages.withColumn("r", F.row_number().over(worst)).where("r = 1").select(
            *_GROUP, "execution_id", F.col("stage_id").alias("worst_stage_id"),
            "max_task_ms", "p50_task_ms", "p95_task_ms",
        ),
        [*_GROUP, "execution_id"],
    )

    has_write = F.max(F.col("is_write").cast("int")) == 1
    first_rows = F.min_by("rows_output", F.when(F.col("rows_output").isNotNull(), F.col("node_id")))
    node_totals = nodes.groupBy(*_GROUP, "execution_id").agg(
        F.array_sort(F.collect_set(F.when(~F.col("is_write"), F.col("table_name")))).alias("read_tables"),
        F.array_sort(F.collect_set(F.when(F.col("is_write"), F.col("table_name")))).alias("written_tables"),
        F.sum("files_read").alias("read_files"),
        F.sum("files_pruned").alias("pruned_files"),
        F.sum("files_written").alias("written_files"),
        F.when(~has_write, first_rows).alias("produced_rows"),
    )

    s = (
        execs.join(plans.drop("nodes"), [*_GROUP, "execution_id"], "left")
        .join(job_state, [*_GROUP, "execution_id"], "left")
        .join(app_over, "group_key", "left")
        .join(app_props, "group_key", "left")
        .join(stage_totals, [*_GROUP, "execution_id"], "left")
        .join(node_totals, [*_GROUP, "execution_id"], "left")
    )
    s = s.select("*", *_links(F.col("props")), *_links(F.col("app_props"), prefix="app_"))
    use_app = F.col("job_link_source").isNull() & (F.col("app_job_link_source") == "cluster_name")
    for c in ("job_id", "job_run_id", "task_run_id", "task_key", "job_link_source"):
        s = s.withColumn(c, F.when(use_app, F.col(f"app_{c}")).otherwise(F.col(c)))
    s = s.withColumn("workspace_id", F.coalesce("workspace_id", "app_workspace_id"))

    status = (
        F.when(F.col("error_fingerprint").isNotNull() | F.coalesce("job_failed", F.lit(False)), "FAILED")
        .when(F.col("end_time").isNotNull(), "FINISHED")
        .when(F.col("app_over"), "FAILED")
    )
    s = s.withColumn("execution_status", status).where(F.col("execution_status").isNotNull())
    s = s.withColumn("statement_id", _statement_id()).withColumn(
        "total_duration_ms",
        (F.unix_millis("end_time") - F.unix_millis("start_time")),
    ).withColumn("error_message", F.col("error_fingerprint"))

    statements = s.select(
        "statement_id", "workspace_id", "cluster_id", "app_id", "execution_id",
        "job_id", "job_run_id", "task_run_id", "task_key", "job_link_source",
        "start_time", "end_time", "total_duration_ms", "execution_status", "error_message",
        "read_bytes", "read_rows", "read_files", "pruned_files", "produced_rows",
        "spilled_local_bytes", "memory_spilled_bytes", "shuffle_read_bytes", "shuffle_write_bytes",
        "written_bytes", "written_rows", "written_files", "total_task_duration_ms", "gc_time_ms",
        "task_count", "failed_task_count", "stage_count",
        "worst_stage_id", "max_task_ms", "p50_task_ms", "p95_task_ms",
        "read_tables", "written_tables", "plan_hash",
    )
    statements = _flag_new_plans(spark, schema, statements)

    look = F.col("execution_status") == "FAILED"
    look = look | (F.coalesce("total_duration_ms", F.lit(0)) >= slow_ms)
    look = look | ((F.coalesce("spilled_local_bytes", F.lit(0)) + F.coalesce("memory_spilled_bytes", F.lit(0))) > 0)
    look = look | F.col("plan_is_new")
    worth = statements.where(look).select("statement_id", "workspace_id", "cluster_id", "app_id", "execution_id")
    node_rows = nodes.join(worth, ["cluster_id", "app_id", "execution_id"]).select(
        "statement_id", "node_id", "parent_node_id", "node_name", "join_type", "table_name",
        "rows_output", "time_ms", "spill_bytes", "peak_memory_bytes", "shuffle_read_bytes",
        "shuffle_write_bytes", "files_read", "files_pruned", "bytes_read", "files_written",
        "other_metrics", "workspace_id", "cluster_id",
    )

    return statements, node_rows, _failures(spark, schema, groups, jobs, stages, statements)


def _flag_new_plans(spark, schema, statements):
    """plan_is_new: this job task's statement (same position, execution_id) ran before with another plan."""
    key = ["job_id", "task_key", "execution_id"]
    cols = [*key, "statement_id", "start_time", "plan_hash"]
    table = f"{schema}.classic_statement_history"
    prior = statements.select(*cols)
    if spark.catalog.tableExists(table):
        prior = spark.table(table).where("job_id IS NOT NULL").select(*cols).unionByName(prior)
    prior = prior.dropDuplicates(["statement_id"]).select(
        *[F.col(c).alias(f"prev_{c}") for c in cols]
    )
    cond = [F.col(k).eqNullSafe(F.col(f"prev_{k}")) for k in key] + [F.col("prev_start_time") < F.col("start_time")]
    joined = statements.where("job_id IS NOT NULL").join(prior, cond).groupBy("statement_id").agg(
        F.max(F.col("prev_plan_hash").eqNullSafe(F.col("plan_hash"))).alias("seen")
    )
    return statements.join(joined, "statement_id", "left").withColumn(
        "plan_is_new", F.coalesce(~F.col("seen"), F.lit(False))
    ).drop("seen")


def _failures(spark, schema, groups, jobs, stages, statements):
    f = spark.table(f"{schema}._classic_partial_failures").join(groups, "group_key", "left_semi")
    f = f.groupBy("group_key", "cluster_id", "app_id", "stage_id", "job_id", "level", "cause",
                  "exception_class", "message_fingerprint").agg(
        F.first("message_template", ignorenulls=True).alias("message_template"),
        F.sum("occurrences").alias("occurrences"),
        F.min("first_seen").alias("first_seen"),
        F.max("last_seen").alias("last_seen"),
    )
    # Link task/stage failures through their stage, job failures through their job, to a statement.
    stage_exec = stages.select(*_GROUP, "stage_id", F.col("execution_id").alias("exec_from_stage"))
    job_exec = jobs.select(*_GROUP, "job_id", F.col("execution_id").alias("exec_from_job"))
    f = f.join(stage_exec, [*_GROUP, "stage_id"], "left").join(job_exec, [*_GROUP, "job_id"], "left")
    f = f.withColumn("execution_id", F.coalesce("exec_from_stage", "exec_from_job"))
    ids = statements.select("cluster_id", "app_id", "execution_id", "workspace_id", "job_id",
                            "job_run_id", "task_run_id", "task_key").withColumnRenamed("job_id", "db_job_id")
    f = f.join(ids, ["cluster_id", "app_id", "execution_id"], "left")
    # Otherwise fall back to the cluster: a job cluster's name names its one job run.
    cluster = spark.table(f"{schema}._classic_partial_jobs").where(F.col("props").isNotNull()).groupBy(
        "cluster_id").agg(F.min_by("props", "job_id").alias("props")).select("cluster_id", *_links(F.col("props")))
    cluster = cluster.where("job_link_source = 'cluster_name'").select(
        "cluster_id", *[F.col(c).alias(f"c_{c}") for c in ("job_id", "task_run_id", "workspace_id")]
    )
    f = f.join(cluster, "cluster_id", "left")
    f = f.withColumn("db_job_id", F.coalesce("db_job_id", "c_job_id")).withColumn(
        "task_run_id", F.coalesce("task_run_id", "c_task_run_id")
    ).withColumn("workspace_id", F.coalesce("workspace_id", "c_workspace_id"))

    key = ["group_key", "task_run_id", "level", "cause", "exception_class", "message_fingerprint"]
    out = f.groupBy(*key).agg(
        F.first("cluster_id").alias("cluster_id"),
        F.first("app_id", ignorenulls=True).alias("app_id"),
        F.first("workspace_id", ignorenulls=True).alias("workspace_id"),
        F.first("db_job_id", ignorenulls=True).alias("job_id"),
        F.first("job_run_id", ignorenulls=True).alias("job_run_id"),
        F.first("task_key", ignorenulls=True).alias("task_key"),
        F.first("message_template", ignorenulls=True).alias("message_template"),
        F.sum("occurrences").alias("occurrences"),
        F.min("first_seen").alias("first_seen"),
        F.max("last_seen").alias("last_seen"),
    )
    failure_id = F.sha2(F.concat_ws("|", *[F.coalesce(F.col(k).cast("string"), F.lit("")) for k in key]), 256)
    return out.select(
        failure_id.substr(1, 32).alias("failure_id"),
        F.col("group_key").alias("run_key"),
        "workspace_id", "cluster_id", "app_id", "job_id", "job_run_id", "task_run_id", "task_key",
        "level", "cause", "exception_class", "message_fingerprint", "message_template",
        "occurrences", "first_seen", "last_seen",
    )
