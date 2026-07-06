-- query_id: query_provenance_by_source
-- source: system.query.history
-- feeds: workload mix/hours; per-query ESTIMATE lane; per-WORKSPACE query provenance; editor-style ad-hoc (sql_editor / notebook) vs scheduled (job) split; who runs ad-hoc — top human users vs service principals (executed_by)
-- confidence: needs_confirmation — verifier status unverifiable
-- NEEDS WORKSPACE CONFIRMATION: the dotted-path SELECT/GROUP BY access syntax against the nested query_source struct — query_source.job_info.job_id, query_source.dashboard_id, query_source.legacy_dashboard_id, query_source.notebook_id, query_source.alert_id, query_source.genie_space_id, query_source.sql_query_id. The subfield names are confirmed; the literal access expression and the single-winner CASE precedence are NOT verbatim in the doc. The doc explicitly says multiple subfields can populate simultaneously and are NOT execution-ordered, so the CASE is a heuristic, not authoritative attribution. Confirm the struct path resolves and decide whether to emit ALL non-null source flags rather than a single CASE winner. No safer-fallback SQL given by the spec — spec SQL used verbatim as primary.
-- caveats: Each subfield is NULL when that entity wasn't involved. Provenance covers Databricks entities only. If grouping by a doubly-nested subfield (job_info.job_id) is rejected, alias the extracted scalar in a subquery before GROUP BY. Also confirm executed_by vs executed_as/executed_as_user_id for run-as / service-principal attribution.
/* databricks_audit:query_provenance_by_source */
-- NEEDS CONFIRMATION: nested-struct dotted-path access + CASE attribution precedence are UNVERIFIED.
-- Confirm the struct path resolves and decide whether to emit ALL non-null source flags
-- rather than a single CASE winner (simultaneous population is documented).
SELECT workspace_id,
       compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       CASE WHEN executed_by IS NULL              THEN 'unknown'
            WHEN executed_by LIKE '%@%'           THEN 'user'
            ELSE 'service_principal' END AS identity_type,
       CASE WHEN executed_by IS NULL              THEN executed_by
            WHEN executed_by LIKE '%@%'           THEN concat(substr(executed_by, 1, 2), '****@****')
            ELSE executed_by END AS executed_by,
       CASE WHEN query_source.job_info.job_id     IS NOT NULL THEN 'job'
            WHEN query_source.dashboard_id        IS NOT NULL THEN 'dashboard'
            WHEN query_source.legacy_dashboard_id IS NOT NULL THEN 'legacy_dashboard'
            WHEN query_source.notebook_id         IS NOT NULL THEN 'notebook'
            WHEN query_source.alert_id            IS NOT NULL THEN 'alert'
            WHEN query_source.genie_space_id      IS NOT NULL THEN 'genie'
            WHEN query_source.sql_query_id        IS NOT NULL THEN 'sql_editor'
            ELSE 'other' END AS source_kind,
       query_source.job_info.job_id AS job_id,
       query_source.dashboard_id    AS dashboard_id,
       query_source.notebook_id     AS notebook_id,
       COUNT(*) AS query_count,
       SUM(execution_duration_ms) AS execution_duration_ms_sum,
       SUM(total_duration_ms)     AS total_duration_ms_sum,
       SUM(read_bytes)            AS read_bytes_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
GROUP BY workspace_id, compute.type, compute.warehouse_id, source_kind,
         CASE WHEN executed_by IS NULL              THEN 'unknown'
              WHEN executed_by LIKE '%@%'           THEN 'user'
              ELSE 'service_principal' END,
         CASE WHEN executed_by IS NULL              THEN executed_by
              WHEN executed_by LIKE '%@%'           THEN concat(substr(executed_by, 1, 2), '****@****')
              ELSE executed_by END,
         query_source.job_info.job_id, query_source.dashboard_id, query_source.notebook_id
