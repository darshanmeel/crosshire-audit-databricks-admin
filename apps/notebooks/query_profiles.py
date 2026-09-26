# Databricks notebook source
# MAGIC %md
# MAGIC # Query profiles: query history -> profile JSON -> Delta tables
# MAGIC
# MAGIC Reads yesterday's `system.query.history`, picks the statements worth a look (failed, spilled,
# MAGIC slow, top task time), downloads each one's profile JSON 4 at a time, parses it in memory and
# MAGIC MERGEs `query_profile_nodes`, `query_profile_summary` and `query_profile_fetch_log`.
# MAGIC The raw JSON (it holds the SQL text) is never saved.
# MAGIC
# MAGIC **Before the first run**, capture the request the UI makes for a profile (see
# MAGIC `apps/crosshire_apps/profiles/PROBE_GUIDE.md`), remove cookies and tokens, put `{statement_id}`
# MAGIC where the statement id was, and paste it into the **request** widget.
# MAGIC
# MAGIC Open this notebook from a Git folder (Repo) of this repository so the `apps/` code is importable.

# COMMAND ----------

dbutils.widgets.text("request", "", "Captured profile request (cURL, cookies removed)")
dbutils.widgets.text("output", "", "catalog.schema for the tables")
dbutils.widgets.text("slow_seconds", "300", "Slow statement threshold (seconds)")
dbutils.widgets.text("top_n", "50", "Top N by task time per warehouse / compute")
dbutils.widgets.text("cap", "500", "Max profiles per day")
dbutils.widgets.text("day", "", "Day to read (YYYY-MM-DD; blank = yesterday)")
dbutils.widgets.dropdown("probe_only", "true", ["true", "false"], "Probe one statement only")

# COMMAND ----------

import os
import re
import sys

# The notebook sits in <repo>/apps/notebooks; make <repo>/apps importable.
nb_path = dbutils.notebook.entry_point.getDbutils().notebook().getContext().notebookPath().get()
apps_dir = "/Workspace" + nb_path.rsplit("/notebooks/", 1)[0]
sys.path.insert(0, apps_dir)

from crosshire_apps.common.key_tree import key_tree, render
from crosshire_apps.profiles import job

request = dbutils.widgets.get("request").strip()
output = dbutils.widgets.get("output").strip()
if not request or "{statement_id}" not in request:
    raise ValueError("paste the captured request with {statement_id} in place of the statement id")
if not re.fullmatch(r"[\w-]+\.[\w-]+", output):
    raise ValueError("output must be catalog.schema")

# The notebook's own session: no personal access token needed. Never printed.
ctx = dbutils.notebook.entry_point.getDbutils().notebook().getContext()
host = "https://" + spark.conf.get("spark.databricks.workspaceUrl")
token = ctx.apiToken().get()
fetch = job.api_source(request, host, token)

# COMMAND ----------

# MAGIC %md
# MAGIC ## 1. Probe: does one fetch work? (prints the result and the key tree, never values)

# COMMAND ----------

import datetime as dt

day = dbutils.widgets.get("day").strip() or (dt.date.today() - dt.timedelta(days=1)).isoformat()
history = spark.table("system.query.history")
sample = job.select_statements(spark, history, output, int(dbutils.widgets.get("slow_seconds")),
                               int(dbutils.widgets.get("top_n")), 1, day).first()
if sample is None:
    print(f"no statement chosen for {day}")
else:
    result, doc = fetch(sample.statement_id)
    print(f"{sample.compute_type} statement: {result}")
    if doc is not None:
        print("\n".join(render(key_tree(doc))))

# COMMAND ----------

# MAGIC %md
# MAGIC ## 2. Daily run (set **probe_only** to false)

# COMMAND ----------

if dbutils.widgets.get("probe_only") == "true":
    dbutils.notebook.exit("probe only; set probe_only = false to fetch and save")

job.run(spark, fetch, output, int(dbutils.widgets.get("slow_seconds")), int(dbutils.widgets.get("top_n")),
        int(dbutils.widgets.get("cap")), day=day)
display(spark.table(f"{output}.query_profile_fetch_log").groupBy("result").count())
