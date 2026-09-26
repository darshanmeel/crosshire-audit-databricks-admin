"""Idempotent Delta writes: MERGE on keys, update only rows whose values changed."""
from delta.tables import DeltaTable
from pyspark.sql import functions as F

SCHEMA_VERSION = 1


def stamp(df):
    return df.withColumn("schema_version", F.lit(SCHEMA_VERSION)).withColumn("loaded_at", F.current_timestamp())


def ensure_table(spark, df, table):
    if not spark.catalog.tableExists(table):
        df.limit(0).write.format("delta").saveAsTable(table)


def _same(col, dtype):
    # Maps can't be compared with <=>; they are written key-sorted, so their JSON compares.
    if dtype.startswith("map"):
        return f"to_json(t.`{col}`) <=> to_json(s.`{col}`)"
    return f"t.`{col}` <=> s.`{col}`"


def merge(spark, df, table, keys, scope=None):
    """Upsert df into table on keys. With scope, target rows whose scope value is in df
    but whose key is not are deleted, so a recomputed statement or run replaces its old rows."""
    ensure_table(spark, df, table)
    target = DeltaTable.forName(spark, table)
    on = " AND ".join(f"t.`{k}` <=> s.`{k}`" for k in keys)
    changed = " OR ".join(
        f"NOT ({_same(c, t)})" for c, t in df.dtypes if c not in keys and c != "loaded_at"
    )
    source = df.withColumn("_delete", F.lit(False))
    if scope:
        gone = (
            spark.table(table)
            .join(df.select(scope).distinct(), scope, "left_semi")
            .join(df.select(*keys), keys, "left_anti")
            .select(*keys)
        )
        source = source.unionByName(gone.withColumn("_delete", F.lit(True)), allowMissingColumns=True)
    (
        target.alias("t")
        .merge(source.alias("s"), on)
        .whenMatchedDelete(condition="s._delete")
        .whenMatchedUpdate(condition=f"NOT s._delete AND ({changed})", set={c: f"s.`{c}`" for c in df.columns})
        .whenNotMatchedInsert(condition="NOT s._delete", values={c: f"s.`{c}`" for c in df.columns})
        .execute()
    )


def replace_paths(spark, df, table, paths):
    """Drop the partial rows of the given source files, then append their new rows."""
    ensure_table(spark, df, table)
    DeltaTable.forName(spark, table).alias("t").merge(
        paths.select("path").distinct().alias("s"), "t.path = s.path"
    ).whenMatchedDelete().execute()
    df.write.format("delta").mode("append").saveAsTable(table)


def table_size(spark, table):
    d = spark.sql(f"DESCRIBE DETAIL {table}").select("sizeInBytes", "numFiles").first()
    return d.sizeInBytes, d.numFiles
