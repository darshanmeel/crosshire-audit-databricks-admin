# Databricks notebook source
# MAGIC %md
# MAGIC # CrossHire Databricks Audit -- notebook runner
# MAGIC
# MAGIC The notebook twin of `tools/run_audit.py`. Reads `queries/manifest.json`, selects queries by
# MAGIC tier / domain / stars, substitutes `:params`, runs each with `spark.sql`, and shows a scorecard.
# MAGIC A query whose table is missing or unreadable is recorded **NOT_ASSESSED** (with the reason),
# MAGIC never silently treated as zero.
# MAGIC
# MAGIC Import this file into a Databricks workspace (or open it from a Repo). It runs read-only unless
# MAGIC you set the **write_to** widget (opt-in, Guardrail 4).

# COMMAND ----------

dbutils.widgets.text("repo_root", "", "Repo root (folder containing queries/)")
dbutils.widgets.text("tier", "lite", "Tiers (comma: lite,standard,deep; blank = all)")
dbutils.widgets.text("domain", "", "Domains (comma; blank = all)")
dbutils.widgets.dropdown("stars_only", "false", ["true", "false"], "First-audit picks only")
dbutils.widgets.text("period_days", "30", "period_days")
dbutils.widgets.text("write_to", "", "OPT-IN: catalog.schema to persist results (blank = read-only)")

# COMMAND ----------

import json, os, re

repo_root = dbutils.widgets.get("repo_root").strip()
if not repo_root:
    # In a Databricks Repo, this notebook sits at <repo>/tools/; queries/ is one level up.
    here = os.path.dirname(os.path.abspath("__file__")) if "__file__" in dir() else os.getcwd()
    repo_root = os.path.dirname(here)
QUERIES = os.path.join(repo_root, "queries")
manifest = json.load(open(os.path.join(QUERIES, "manifest.json"), encoding="utf-8"))

tiers = {t for t in dbutils.widgets.get("tier").split(",") if t.strip()}
domains = {d for d in dbutils.widgets.get("domain").split(",") if d.strip()}
stars_only = dbutils.widgets.get("stars_only") == "true"
period_days = int(dbutils.widgets.get("period_days"))
write_to = dbutils.widgets.get("write_to").strip()
# H1: write_to is interpolated into DDL -> require a plain catalog.schema identifier.
if write_to and not re.match(r"^[A-Za-z0-9_]+\.[A-Za-z0-9_]+$", write_to):
    raise ValueError(f"write_to must be 'catalog.schema' (letters, digits, underscore only), got {write_to!r}")

known = {p["name"] for dom in manifest.values() for e in dom for p in e["params"]}

selected = [
    e for dom, entries in manifest.items() if not domains or dom in domains
    for e in entries
    if (not tiers or e["tier"] in tiers) and (not stars_only or e["stars"])
]
print(f"{len(selected)} queries selected")

# COMMAND ----------

# Error CLASSES that mean "data not available to assess" (see run_audit.py H2): match bracketed
# error codes, NOT prose like "does not exist" that also appears in genuine query bugs.
NOT_ASSESSED = ["TABLE_OR_VIEW_NOT_FOUND", "SCHEMA_NOT_FOUND", "CATALOG_NOT_FOUND",
                "INSUFFICIENT_PERMISSIONS", "INSUFFICIENT_PRIVILEGES", "PERMISSION_DENIED",
                "UC_NOT_ENABLED", "FEATURE_NOT_ENABLED"]

def resolve_sql(entry):
    path = os.path.join(QUERIES, entry["domain"], entry["query_id"] + ".sql")
    body = "\n".join(l for l in open(path, encoding="utf-8") if not l.startswith("--"))
    values = {p["name"]: p["default"] for p in entry["params"]}
    values["period_days"] = period_days
    pat = r":(" + "|".join(sorted(known, key=len, reverse=True)) + r")\b"
    def repl(m):
        v = values[m.group(1)]; float(v); return str(v)   # numeric -> safe inline
    return re.sub(pat, repl, body).strip().rstrip(";")

def status_summary(df):
    if "status" not in df.columns:
        return ""
    rows = df.groupBy("status").count().collect()
    return " ".join(f"{r['status']}={r['count']}" for r in rows)

rows_out = []
for e in selected:
    qid = e["query_id"]
    sql = resolve_sql(e)
    try:
        if write_to:
            cat, sch = write_to.split(".")
            target = f"`{cat}`.`{sch}`.`{qid}`"  # backtick-quoted identifier (H1)
            spark.sql(f"CREATE OR REPLACE TABLE {target} AS {sql}")
            df = spark.table(target)
        else:
            df = spark.sql(sql)
        n = df.count()
        rows_out.append((qid, e["domain"], e["tier"], "OK", n, status_summary(df)))
    except Exception as ex:
        msg = str(ex)
        outcome = "NOT_ASSESSED" if any(s.lower() in msg.lower() for s in NOT_ASSESSED) else "ERROR"
        rows_out.append((qid, e["domain"], e["tier"], outcome, 0, msg.splitlines()[0][:80]))

# COMMAND ----------

# MAGIC %md ## Scorecard

# COMMAND ----------

scorecard = spark.createDataFrame(
    rows_out, "query_id string, domain string, tier string, outcome string, rows long, detail string"
)
display(scorecard.orderBy("outcome", "domain", "query_id"))

# COMMAND ----------

display(scorecard.groupBy("outcome").count())
if write_to:
    print(f"results persisted under {write_to}.<query_id>")
