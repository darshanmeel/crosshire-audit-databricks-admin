-- query_id: query_costly_statements_grouped
-- title: Heaviest SQL statement shapes, rolled up by fingerprint
-- domain: performance   tier: standard
-- reads: system.query.history
-- requires: SELECT on system.query; GA
-- params: :period_days (default 30) rolling window in days; :warn_total_hours (default 1) cumulative execution hours for a single shape that flags WARN; :crit_total_hours (default 5) same for CRITICAL; :top_n (default 500) row cap
-- confidence: confirmed
-- confidence_note: system.query.history columns verified in a live workspace; the sibling of query_costly_statements.
-- read_this: One row = one distinct statement SHAPE (statement_fingerprint) run one or more times. total_exec_ms (cumulative execution time across every run) is the column that matters - a cheap statement run 10,000 times can outweigh one heavy query. runs and avg_exec_ms tell you whether to fix the shape or its frequency.
-- healthy: total_exec_ms below :warn_total_hours hours over the window (field heuristic - tune for your account).
-- investigate_if: total_exec_ms at/above :warn_total_hours (WARN) or :crit_total_hours (CRITICAL) cumulative hours - a hot repeated shape (field heuristic). High runs + low avg_exec_ms means fix the caller (frequency / caching); high avg_exec_ms means tune the statement.
-- actions: 1) cache or materialize the result when the same shape reruns with the same inputs, and dedupe callers (free); 2) batch / schedule the repeated shape, or move it to a right-sized warehouse (config); 3) scale only the genuinely heavy shapes, after tuning (spend).
-- next: query_costly_statements (to see the individual runs behind a fingerprint), query_pruning_effectiveness (if a hot shape scans far more files than it prunes)
-- caveats: statement_fingerprint groups statements whose SHAPE matches after de-valuing literals, so two queries that differ only in string / number literals collapse to one fingerprint (intended). PRIVACY: sample_statement_text is de-valued (emails and single-quoted literals stripped) and the fingerprint is a sha2 of that text - not reversible to the original query. Cumulative execution time approximates cost only loosely ACROSS warehouses of different sizes (Databricks has no per-query dollar column; see query_costly_statements for per-warehouse framing). Serverless rows carry warehouse_id NULL, so distinct_warehouses counts NULL as one bucket.
-- system.query.history only captures statements run on SQL warehouses or serverless compute; work on classic all-purpose/job clusters is never recorded, so a heavy shape running on classic compute will not appear here at all.
WITH devalued AS (
  SELECT
    statement_type,
    compute.warehouse_id AS warehouse_id,
    start_time,
    execution_duration_ms,
    regexp_replace(
      regexp_replace(statement_text, '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'),
      concat(chr(39), '[^', chr(39), ']*', chr(39)), '?'
    ) AS statement_text
  FROM system.query.history
  WHERE start_time >= dateadd(DAY, -:period_days, current_date())
    AND start_time <  current_date()
    AND execution_status = 'FINISHED'
    AND from_result_cache = false
    AND execution_duration_ms > 0
),
fp AS (
  SELECT sha2(statement_text, 256) AS statement_fingerprint, *
  FROM devalued
)
SELECT
  statement_fingerprint,
  MAX(statement_type)                       AS statement_type,
  min(statement_text)                        AS sample_statement_text,
  COUNT(*)                                   AS runs,
  SUM(execution_duration_ms)                 AS total_exec_ms,
  CAST(AVG(execution_duration_ms) AS BIGINT) AS avg_exec_ms,
  MAX(execution_duration_ms)                 AS max_exec_ms,
  COUNT(DISTINCT warehouse_id)               AS distinct_warehouses,
  MIN(start_time)                            AS first_seen,
  MAX(start_time)                            AS last_seen,
  -- status: worst-first band on cumulative execution time for the shape (field heuristic).
  CASE
    WHEN SUM(execution_duration_ms) >= :crit_total_hours * 3600 * 1000 THEN 'CRITICAL'
    WHEN SUM(execution_duration_ms) >= :warn_total_hours * 3600 * 1000 THEN 'WARN'
    ELSE 'OK'
  END AS status
FROM fp
GROUP BY statement_fingerprint
ORDER BY total_exec_ms DESC
LIMIT :top_n
