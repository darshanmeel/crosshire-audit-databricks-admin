# CrossHire apps: cluster logs and query profiles → small audit tables

Two daily Databricks jobs that turn what the Databricks UI shows (query history plus the query
profile) into a few small Delta tables for the read-only CrossHire audit app. Unlike the SQL
library in `../queries/`, these jobs **write** tables, so they live in their own folder.

| Part | Status |
|---|---|
| **Classic clusters** (`crosshire_apps/classic`): cluster log delivery → `classic_statement_history`, `classic_query_profile_nodes`, `classic_failures` | Built and tested on synthetic logs and on a local OSS Spark event log. **Not yet run on real Databricks logs.** |
| **SQL warehouses and serverless** (`crosshire_apps/profiles`): query profile → `query_profile_nodes`, `query_profile_summary`, `query_profile_fetch_log` | Step 1 only: the probe that finds out whether a profile can be fetched with a token. |

## Classic clusters

### Step 1: inventory a real cluster folder

Run on a cluster that can read the log destination:

```bash
python -m crosshire_apps.classic.inventory /Volumes/<catalog>/<schema>/<volume>/<cluster_id>
```

It prints the files and sizes, a count of each `Event` type, the key tree (names, types,
list lengths) of one event of each type, and the JobStart property names under
`spark.databricks.*`. It never prints a value, and config maps are collapsed to a key count.

### The daily job

```bash
pip wheel --no-deps -w dist .          # then attach the wheel to the job
# python_wheel_task, entry point classic-logs-job, parameters:
--log-root /Volumes/ops/logs/clusters  # repeatable
--output main.crosshire_audit          # catalog.schema
--clusters all                         # or ids:<id>,<id> | tag:<key>=<value> | job:<job_id>,<job_id>
--slow-seconds 300                     # plan trees are kept for statements at least this slow
```

`tag:` and `job:` look the clusters up in `system.compute.clusters`. After each run the job
prints the row count and size of each output table.

### How it works

1. **List** every `eventlog*`, `stderr*` and `log4j*` file under the roots (never `stdout`, never
   init scripts) and keep only files whose path, size or modified time is new
   (`_classic_file_state`). A file that grew is read again in full.
2. **Parse with Spark.** Lines are read as text, the `Event` field is picked with
   `get_json_object`, and unneeded events (environment, block manager, task start, …) are
   dropped before any JSON is parsed. Task rows are aggregated to stage attempts right away.
3. **Partials.** Each file's aggregates go to `_classic_partial_*` tables keyed by the file's
   path, so re-reading a file replaces its rows instead of adding to them. This is what makes
   a growing file, and a statement whose events span several hourly files, come out right.
4. **Assemble** the three tables for every app touched in this run, from all its partials, and
   MERGE them in. A row is only updated when a value changed, so rerunning a day changes
   nothing (not even `loaded_at`). Plan nodes and failures of a recomputed statement or run
   replace the old ones.
5. **Prune** partials of apps whose files have not changed for 7 days.

Details worth knowing:

- `statement_id` = `<cluster_id>:<app_id>:<execution_id>`. `app_id` is the name of the folder the
  event log sits in (the Spark context folder); the App ID event is only in the first file of
  an app, so it can't be used for files read later.
- The plan is the last `SparkListenerSQLAdaptiveExecutionUpdate` (else the start event's plan).
  Node ids are the preorder position in that tree. Node metrics are the sum of successful task
  updates plus driver-side updates, as in the Spark UI; stage totals include failed tasks'
  metrics, as the Spark UI stage table does.
- `p50_task_ms`/`p95_task_ms` come from a log-scale histogram (4 buckets per doubling), so they
  are within about 9%. `max_task_ms` is exact.
- A statement with no end event is written as `FAILED` (with `end_time` NULL) once the app has
  logged its end or none of its files changed for 24 hours: a driver crash never logs an end.
- `plan_is_new`: the same job, task key and `execution_id` ran before with a different
  `plan_hash`. Only job statements can be compared; execution ids restart for each job
  cluster, so the same position in the same job is the same statement.
- Plan trees (`classic_query_profile_nodes`) are kept for statements that are slow, spilled,
  failed or have a new plan. Every statement still gets its history row.
- Job ids come from the JobStart properties `spark.databricks.job.*`, else from a job
  cluster's name `job-<job_id>-run-<task_run_id>`; `job_link_source` records which.
- Failures: task (failed task end reasons), stage (failure reason), job (failed job), executor
  (removed executors; scale-down removals are skipped) and driver/executor text logs
  (exception lines in `stderr` and `log4j`). Text logs belong to the cluster, not an app, so
  their `run_key` is `<cluster_id>/text/<date>`.

### Privacy

Kept: ids, numbers, operator names, table names, exception classes, message fingerprints
(values stripped, then hashed) and message templates. Never kept: raw log lines, SQL text,
`simpleString`/plan text, literal values, paths below table roots, stdout, the environment
event, or any JobStart property outside a short allow-list (`events.JOB_PROPERTIES`). No user
names are stored. `tests/test_classic_job.py::test_privacy` scans every table, partials
included, for the markers planted in the synthetic logs.

## SQL warehouses and serverless: step 1

See [`crosshire_apps/profiles/PROBE_GUIDE.md`](crosshire_apps/profiles/PROBE_GUIDE.md): capture
the request the UI makes, strip cookies and tokens, then run
`python -m crosshire_apps.profiles.probe_profile --curl request.txt --statement-id <id>` for a
warehouse statement, a serverless notebook statement and a serverless job statement.

## Tests

```bash
pip install -r requirements-dev.txt   # needs Java 17 for local Spark
pytest                                # the Spark tests take ~10 minutes
```

Unit tests use hand-written event lines (`tests/synthetic.py`); no real log content is in the
repo.
