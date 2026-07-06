-- query_id: lakeflow_pipeline_update_failures_retries
-- source: system.lakeflow.pipeline_update_timeline (Public Preview)
-- feeds: DLT/Lakeflow pipeline tier + idle tail; failed runs; retries/repairs
-- confidence: confirmed
-- caveats: Public Preview (degrade if disabled/empty). result_state end-row-only. Values: COMPLETED/FAILED/CANCELED (one L); update_type FULL_REFRESH/REFRESH/VALIDATE; trigger_type='RETRY_ON_FAILURE' confirmed. request_id groups retried/restarted updates (retry signal).
/* databricks_audit:lakeflow_pipeline_update_failures_retries */
WITH end_rows AS (
  SELECT workspace_id, pipeline_id, update_id, request_id, update_type,
         trigger_type, result_state, period_start_time, period_end_time
  FROM system.lakeflow.pipeline_update_timeline
  WHERE period_start_time >= date_add(current_date(), -30)
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL          -- end row only for updates >1h
)
SELECT e.workspace_id, e.pipeline_id, e.update_type, e.trigger_type, e.result_state,
       COUNT(DISTINCT e.update_id) AS updates,
       SUM(CASE WHEN e.result_state = 'FAILED'             THEN 1 ELSE 0 END) AS failed_update_rows,
       SUM(CASE WHEN e.trigger_type = 'RETRY_ON_FAILURE'   THEN 1 ELSE 0 END) AS retry_triggered_rows
FROM end_rows e
GROUP BY e.workspace_id, e.pipeline_id, e.update_type, e.trigger_type, e.result_state
