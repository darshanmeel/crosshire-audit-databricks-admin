-- query_id: query_costly_statements
-- source: system.query.history
-- feeds: performance-tuning — the heaviest individual SQL statements by execution time (~= DBU cost),
--        with per-statement pruning / shuffle / spill / scan-amplification signals to diagnose the fix.
-- confidence: confirmed
-- caveats: Databricks has NO per-query dollar column; warehouse DBUs are allocated in proportion to
--          execution_duration_ms, so ranking by execution_duration_ms ~= ranking by cost. Serverless
--          rows carry warehouse_id NULL and attribute cost differently. PRIVACY: executed_by is
--          partial-masked at source (our house style), and statement_text has emails + single-quoted
--          string literals stripped at source so only the query SHAPE (identifiers/structure) — never
--          data values — leaves the workspace. The '--share' full-redact build truncates statement_text
--          entirely.
/* databricks_audit:query_costly_statements */
SELECT
  workspace_id,
  statement_id,
  statement_type,
  -- executed_by: partial-unmask (house style) — keep an email as da****@****, keep a service-principal
  -- GUID as-is (opaque handle), else first-2-chars + ****. No raw username/email reaches the CSV.
  CASE
    WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
    WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
    WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
    ELSE concat(substr(executed_by, 1, 2), '****')
  END                                    AS executed_by,
  compute.warehouse_id                   AS warehouse_id,
  compute.type                           AS compute_type,
  start_time,
  execution_duration_ms,
  waiting_for_compute_duration_ms,
  total_task_duration_ms,
  read_bytes,
  read_files,
  pruned_files,
  read_partitions,
  read_rows,
  produced_rows,
  spilled_local_bytes,
  shuffle_read_bytes,
  from_result_cache,
  -- statement_text de-valued at source: strip emails, then replace every single-quoted string literal
  -- with '?' (chr(39) is the single quote, avoiding SQL-string escaping). Keeps the query shape
  -- (table/column identifiers, structure) while removing literal data values.
  regexp_replace(
    regexp_replace(statement_text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'),
    concat(chr(39), '[^', chr(39), ']*', chr(39)), '?'
  )                                      AS statement_text
FROM system.query.history
WHERE start_time >= dateadd(day, -:period_days, current_date())
  AND start_time <  current_date()
  AND execution_status = 'FINISHED'
  AND from_result_cache = false
  AND execution_duration_ms > 0
ORDER BY execution_duration_ms DESC
LIMIT 1000
