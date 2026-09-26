"""Step 1: inventory one real cluster log folder without printing any log content.

    python -m crosshire_apps.classic.inventory /Volumes/ops/logs/clusters/<cluster_id>

Prints the files and sizes, a count of each Event type, and the key tree (names, types,
list lengths) of one event of each type. Values are never printed.
"""
import json
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

from crosshire_apps.classic.events import decoded_path
from crosshire_apps.common.key_tree import key_tree, render

# Maps whose key names are themselves config names, paths or accounts: show only their size.
COLLAPSE = {"Spark Properties", "Hadoop Properties", "System Properties", "Metrics Properties",
            "Classpath Entries", "JVM Information", "Properties", "modifiedConfigs", "Executor Resources",
            "Task Resources", "Resource Profiles"}


def collapse(value):
    if isinstance(value, dict):
        return {k: {"<collapsed, key count>": len(v)} if k in COLLAPSE and isinstance(v, (dict, list))
                else collapse(v) for k, v in value.items()}
    if isinstance(value, list):
        return [collapse(v) for v in value]
    return value


def main(folder):
    spark = SparkSession.builder.getOrCreate()
    files = (
        spark.read.format("binaryFile").option("recursiveFileLookup", "true").load(folder)
        .select("path", "length", "modificationTime").orderBy("path")
    )
    print("== files (path below the folder, bytes, modified)")
    total = 0
    for r in files.collect():
        total += r.length
        print(f"{r.path.split(folder.rstrip('/'), 1)[-1]}\t{r.length}\t{r.modificationTime}")
    print(f"total bytes: {total}")

    event_files = [r.path for r in files.where(F.col("path").rlike("/eventlog/")).collect()]
    if not event_files:
        print("no eventlog files found")
        return
    lines = spark.read.text(event_files).select(
        "value", decoded_path(F.col("_metadata.file_path")).alias("path")
    ).withColumn("event", F.get_json_object("value", "$.Event"))
    print("\n== events per type (unparseable lines are counted as NULL)")
    for r in lines.groupBy("event").count().orderBy(F.desc("count")).collect():
        print(f"{r['count']}\t{r.event}")

    print("\n== key tree of one event of each type (values are never printed)")
    samples = lines.where("event IS NOT NULL").groupBy("event").agg(F.first("value").alias("value")).collect()
    for r in sorted(samples, key=lambda r: r.event):
        print(f"\n-- {r.event}")
        print("\n".join(render(key_tree(collapse(json.loads(r.value))))))

    # The job links need these; list which JobStart property names exist (names only).
    props = lines.where(F.col("event") == "SparkListenerJobStart").select(
        F.explode(F.map_keys(F.from_json(F.get_json_object("value", "$.Properties"), "map<string,string>")))
        .alias("k")
    ).where(F.col("k").rlike(r"^spark\.(databricks|sql\.execution|job)")).distinct().orderBy("k")
    print("\n== JobStart property names under spark.databricks / spark.sql.execution / spark.job")
    for r in props.collect():
        print(r.k)


if __name__ == "__main__":
    main(sys.argv[1])
