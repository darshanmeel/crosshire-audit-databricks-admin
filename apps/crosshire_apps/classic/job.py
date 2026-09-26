"""Daily job: read new or changed classic cluster log files, update the three tables.

    python -m crosshire_apps.classic.job --log-root /Volumes/ops/logs/clusters \
        --output main.crosshire_audit --clusters all --slow-seconds 300
"""
import argparse
import re

from delta.tables import DeltaTable
from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from crosshire_apps.classic import assemble, events
from crosshire_apps.common.delta_io import merge, replace_paths, stamp, table_size

# Partials of an app nobody wrote to for this long are dropped; its statements are final.
PARTIAL_RETENTION_DAYS = 7
OUTPUT_TABLES = ["classic_statement_history", "classic_query_profile_nodes", "classic_failures"]
PARTIALS = ["plans", "execs", "accums", "jobs", "stages", "failures", "app_ends"]


def parse_args(argv=None):
    a = argparse.ArgumentParser()
    a.add_argument("--log-root", required=True, action="append", help="log delivery destination; repeatable")
    a.add_argument("--output", required=True, help="catalog.schema for the tables")
    a.add_argument("--clusters", required=True, help="all | ids:<id>,<id> | tag:<key>=<value> | job:<job_id>,<job_id>")
    a.add_argument("--slow-seconds", required=True, type=int, help="keep plan trees of statements at least this slow")
    args = a.parse_args(argv)
    if not re.fullmatch(r"[\w-]+\.[\w-]+", args.output):
        a.error("--output must be catalog.schema")
    return args


def selected_clusters(spark, spec):
    """None means all clusters; else a DataFrame of cluster_id."""
    kind, _, value = spec.partition(":")
    if kind == "all":
        return None
    if kind == "ids":
        return spark.createDataFrame([(c.strip(),) for c in value.split(",") if c.strip()], "cluster_id string")
    clusters = spark.table("system.compute.clusters")
    if kind == "tag":
        key, _, tag_value = value.partition("=")
        return clusters.where(F.col("tags")[key] == tag_value).select("cluster_id").distinct()
    if kind == "job":
        ids = "|".join(re.escape(j.strip()) for j in value.split(","))
        return clusters.where(F.col("cluster_name").rlike(f"^job-({ids})-run-")).select("cluster_id").distinct()
    raise ValueError(f"unknown --clusters value: {spec}")


def list_files(spark, roots, clusters):
    """Every event log, stderr and log4j file under the roots; never stdout or init scripts."""
    listing = None
    for root in roots:
        df = (
            spark.read.format("binaryFile")
            .option("recursiveFileLookup", "true")
            .load(root.rstrip("/"))
            .select("path", F.col("length").alias("size"), F.col("modificationTime").alias("modification_time"))
        )
        listing = df if listing is None else listing.unionByName(df)
    listing = listing.withColumn("path", events.normalise_path(F.col("path")))
    name = F.regexp_extract("path", r"([^/]+)$", 1)
    kind = (
        F.when(F.col("path").rlike(r"/eventlog/") & name.startswith("eventlog"), "eventlog")
        .when(F.col("path").rlike(r"/(driver|executor)/") & (name.startswith("stderr") | name.startswith("log4j")), "text")
    )
    listing = listing.withColumn("kind", kind).where(F.col("kind").isNotNull())
    listing = listing.withColumn(
        "cluster_id", F.regexp_extract("path", r"/([^/]+)/(?:eventlog|driver|executor)/", 1)
    )
    if clusters is not None:
        listing = listing.join(clusters, "cluster_id", "left_semi")
    app_dir = F.regexp_extract("path", r"^(.*)/[^/]+$", 1)
    group_key = F.when(
        F.col("kind") == "eventlog", F.concat_ws("/", "cluster_id", F.regexp_extract(app_dir, r"([^/]+)$", 1))
    ).otherwise(F.concat_ws("/", "cluster_id", F.lit("text"), F.to_date("modification_time").cast("string")))
    return listing.withColumn("group_key", group_key)


def new_or_changed(spark, schema, listing):
    state = f"{schema}._classic_file_state"
    if not spark.catalog.tableExists(state):
        return listing
    seen = spark.table(state).select("path", "size", "modification_time")
    return listing.join(seen, ["path", "size", "modification_time"], "left_anti")


def extract_partials(spark, batch):
    event_paths = [r.path for r in batch.where("kind = 'eventlog'").select("path").collect()]
    text_paths = [r.path for r in batch.where("kind = 'text'").select("path").collect()]
    out = {}
    if event_paths:
        ev = events.read_events(spark, event_paths).cache()
        out = {
            "plans": events.plans(ev),
            "execs": events.executions(ev),
            "accums": events.accumulators(ev),
            "jobs": events.jobs(ev),
            "stages": events.stages(ev),
            "failures": events.failures(ev),
            "app_ends": events.app_ends(ev),
        }
    if text_paths:
        text = events.text_log_failures(spark, text_paths)
        out["failures"] = out["failures"].unionByName(text) if "failures" in out else text
    return out


def open_groups(spark, schema):
    """App groups with a statement that has no end yet: it may turn FAILED as the app goes idle."""
    t = f"{schema}._classic_partial_execs"
    if not spark.catalog.tableExists(t):
        return spark.createDataFrame([], "group_key string")
    return (
        spark.table(t).groupBy("group_key", "execution_id").agg(F.max("end_time").alias("e"))
        .where("e IS NULL").select("group_key").distinct()
    )


def prune(spark, schema):
    state = f"{schema}._classic_file_state"
    stale = spark.table(state).groupBy("group_key").agg(F.max("modification_time").alias("m")).where(
        F.col("m") < F.current_timestamp() - F.expr(f"INTERVAL {PARTIAL_RETENTION_DAYS} DAYS")
    ).select("group_key")
    for name in PARTIALS:
        table = f"{schema}._classic_partial_{name}"
        if spark.catalog.tableExists(table):
            DeltaTable.forName(spark, table).alias("t").merge(
                stale.alias("s"), "t.group_key = s.group_key"
            ).whenMatchedDelete().execute()


def run(spark, roots, schema, clusters_spec, slow_seconds, now=None):
    listing = list_files(spark, roots, selected_clusters(spark, clusters_spec))
    batch = new_or_changed(spark, schema, listing).cache()
    n_files = batch.count()
    print(f"new or changed files: {n_files}")

    for name, df in extract_partials(spark, batch).items():
        replace_paths(spark, df, f"{schema}._classic_partial_{name}", batch)
    groups = batch.select("group_key").unionByName(open_groups(spark, schema)).distinct().cache()
    if spark.catalog.tableExists(f"{schema}._classic_partial_execs") and groups.count():
        statements, nodes, failures = assemble.build(spark, schema, groups, listing, slow_seconds * 1000, now)
        merge(spark, stamp(statements), f"{schema}.classic_statement_history", ["statement_id"])
        merge(spark, stamp(nodes), f"{schema}.classic_query_profile_nodes", ["statement_id", "node_id"],
              scope="statement_id")
        merge(spark, stamp(failures), f"{schema}.classic_failures", ["failure_id"], scope="run_key")
    # State last: if the run dies before this, the same files are simply read again.
    state = batch.select("path", "size", "modification_time", "kind", "group_key").withColumn(
        "processed_at", F.current_timestamp()
    )
    merge(spark, state, f"{schema}._classic_file_state", ["path"])
    prune(spark, schema)

    for t in OUTPUT_TABLES:
        full = f"{schema}.{t}"
        if spark.catalog.tableExists(full):
            size, files = table_size(spark, full)
            print(f"{t}: {spark.table(full).count()} rows, {size / 1e6:.2f} MB in {files} files")


def main(argv=None):
    args = parse_args(argv)
    spark = SparkSession.builder.getOrCreate()
    run(spark, args.log_root, args.output, args.clusters, args.slow_seconds)


if __name__ == "__main__":
    main()
