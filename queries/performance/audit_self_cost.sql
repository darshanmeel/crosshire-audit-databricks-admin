-- query_id: audit_self_cost
-- source: system.query.history
-- feeds: Audit Cost tab — what running THIS audit cost the workspace
-- confidence: confirmed (measured magnitude). Reports COUNT + runtime of the audit's own
--   queries; Databricks does NOT expose per-query DBU, so the engine reports magnitude and
--   marks the dollar 'not assessed' (parity with the rest of the DBX dollar stance) unless a
--   DBU rate is supplied downstream.
-- caveats: INVERSE of self-exclusion — INCLUDES the audit's own queries on purpose. Every
--   CrossHire query embeds the /* databricks_audit:<id> */ marker, so we match on statement_text.
--   system.query.history has short ingest latency, so the most recent minutes of the in-flight
--   run may not be reflected yet; the figure is cumulative across audit runs in the window.
--   No upper-bound on start_time so today's (this run's) landed queries are included.
/* databricks_audit:audit_self_cost */
SELECT
    workspace_id,
    statement_type,
    COUNT(*)                                   AS query_count,
    SUM(total_duration_ms) / 1000.0            AS total_duration_secs,
    SUM(COALESCE(total_task_duration_ms, 0)) / 1000.0 AS total_task_secs,
    COUNT(DISTINCT executed_by)                AS distinct_principals,
    MIN(start_time)                            AS first_query_time,
    MAX(start_time)                            AS last_query_time
FROM system.query.history
WHERE start_time >= dateadd(day, -:period_days, current_date())
  AND statement_text ILIKE '%databricks_audit%'
GROUP BY workspace_id, statement_type;
