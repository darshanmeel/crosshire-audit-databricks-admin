-- query_id: lakeflow_health_rule_coverage
-- source: system.lakeflow.jobs
-- feeds: Job Health page — health-rule coverage across active jobs (reliability-3)
-- confidence: needs_confirmation
-- caveats: health_rules is "not populated before late Nov 2025" — so on short-history accounts the column is NULL for every job and CANNOT be read as "no health rule configured". We expose jobs_health_rules_null separately so a fully-NULL column degrades to "not assessed — column not yet populated" downstream; only a job that EXISTS in a populated window with an empty/absent rule set is a confident "no coverage" signal. jobs is SCD2 -> latest row per (workspace_id, job_id) by change_time, then delete_time IS NULL to drop user-deleted jobs (must-fix: dedupe change-history before counting or jobs inflate). job_id unique only within a workspace -> partition includes workspace_id.
-- NEEDS WORKSPACE CONFIRMATION: health_rules is documented as a STRUCT/array; the "has a rule configured" test here uses CARDINALITY(health_rules) > 0, which assumes it is an array-typed column. If health_rules is a scalar/STRING on this account, the engine reads the *_null bucket only and degrades the coverage % gracefully rather than mis-reporting.
/* databricks_audit:lakeflow_health_rule_coverage */
WITH latest_jobs AS (
  SELECT workspace_id, job_id, name, health_rules, delete_time
  FROM system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY workspace_id, job_id ORDER BY change_time DESC
  ) = 1
)
SELECT workspace_id,
       COUNT(*) AS active_jobs,
       -- NULL = column not yet populated (unknown), reported as a separate not-assessed bucket
       SUM(CASE WHEN health_rules IS NULL THEN 1 ELSE 0 END) AS jobs_health_rules_null,
       -- confident "has a health rule": non-null AND a non-empty rule set
       SUM(CASE WHEN health_rules IS NOT NULL AND CARDINALITY(health_rules) > 0
                THEN 1 ELSE 0 END)                            AS jobs_with_health_rule,
       -- confident "no health rule": non-null but empty rule set (populated window, no rule)
       SUM(CASE WHEN health_rules IS NOT NULL AND CARDINALITY(health_rules) = 0
                THEN 1 ELSE 0 END)                            AS jobs_no_health_rule
FROM latest_jobs
WHERE delete_time IS NULL
GROUP BY workspace_id
