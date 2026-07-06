-- query_id: lakeflow_termination_type_probe
-- source: system.lakeflow.job_run_timeline
-- feeds: termination taxonomy
-- confidence: needs_confirmation — verifier status `unverifiable`
-- NEEDS WORKSPACE CONFIRMATION: termination_type — the column is confirmed to exist, but its distinct value list is UNVERIFIED and it is not populated before early Dec 2025. This query is a runtime discovery probe (groups by the raw column, hardcodes no values).
-- caveats: This probe discovers distinct termination_type values at runtime; confirm the column populates on the account.
/* databricks_audit:lakeflow_termination_type_probe */
-- NEEDS CONFIRMATION: termination_type column exists but its value enum is UNVERIFIED.
-- This probe discovers distinct values at runtime; confirm the column populates on the account.
SELECT workspace_id, termination_type, COUNT(*) AS run_rows
FROM system.lakeflow.job_run_timeline
WHERE period_start_time >= date_add(current_date(), -30)
  AND result_state IS NOT NULL
GROUP BY workspace_id, termination_type
