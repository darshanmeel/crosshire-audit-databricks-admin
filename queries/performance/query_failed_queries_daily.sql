-- query_id: query_failed_queries_daily
-- source: system.query.history
-- feeds: failed queries
-- confidence: confirmed
-- caveats: execution_status enum FINISHED/FAILED/CANCELED. error_message is EMPTY under customer-managed keys (CMK) — MAX() returns blank then; degrade. Preview table + the query schema must be enabled. Regional. Classic/all-purpose clusters NOT captured.
/* databricks_audit:query_failed_queries_daily */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       execution_status, statement_type,
       CASE
         WHEN executed_by IS NULL OR executed_by = '__REDACTED__' THEN executed_by
         WHEN executed_by LIKE '%@%' THEN concat(substr(executed_by, 1, 2), '****@****')
         WHEN executed_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN executed_by
         ELSE concat(substr(executed_by, 1, 2), '****')
       END AS executed_by,
       COUNT(*) AS query_count,
       SUM(total_duration_ms)     AS total_duration_ms_sum,
       SUM(execution_duration_ms) AS execution_duration_ms_sum,
       -- error text de-valued at source: strip emails, then single-quoted string literals (chr(39) is
       -- the single quote) — keeps the error SHAPE, drops literal data values. (share build truncates it.)
       regexp_replace(
         regexp_replace(MAX(error_message), '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+[.][A-Za-z]{2,}', '<email>'),
         concat(chr(39), '[^', chr(39), ']*', chr(39)), '?'
       )                          AS error_message_sample
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
  AND execution_status IN ('FAILED','CANCELED')
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id, execution_status, statement_type, executed_by
