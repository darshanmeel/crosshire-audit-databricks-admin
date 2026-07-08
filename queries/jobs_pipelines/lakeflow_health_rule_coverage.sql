-- query_id: lakeflow_health_rule_coverage
-- title: Job health-rule coverage across active jobs
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.jobs
-- requires: SELECT on system.lakeflow; GA (system.lakeflow.jobs is generally available; health_rules was added late Nov 2025)
-- empty_if: schema_not_enabled, submit_run_skipped
-- params: :warn_coverage_pct (default 50) percent of active jobs with a health rule below which a workspace flags WARN; :crit_coverage_pct (default 20) percent below which it flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: health_rules is documented as an array/struct column; whether CARDINALITY(health_rules) > 0 is the right "has a rule" test on this account is unverified, and the column is not populated before late Nov 2025.
-- read_this: One row = a workspace. The columns that matter are jobs_with_health_rule vs active_jobs (coverage), and jobs_health_rules_null, which tells you whether the column is populated at all on this account before you trust the coverage number.
-- healthy: jobs_health_rules_null is 0 (column populated) and jobs_with_health_rule / active_jobs stays above :warn_coverage_pct percent - field heuristic; tune for your account.
-- investigate_if: jobs_health_rules_null > 0 (coverage is not assessable yet - column not populated), or coverage falls below :warn_coverage_pct percent (WARN) / :crit_coverage_pct percent (CRITICAL) - field heuristic.
-- actions: 1) pick the highest-DBU jobs with no health rule and add a duration/failure health rule to each (free); 2) make health-rule configuration part of your job-creation checklist or template (config); 3) n/a - this finding does not itself justify new spend.
-- next: lakeflow_job_ownership_orphans (for the related governance-coverage picture), lakeflow_jobs_no_timeout (another active-job config gap worth checking alongside)
-- caveats: health_rules was not populated before late Nov 2025, so on a short-history account the column is NULL for every job; a fully-NULL column is reported separately as jobs_health_rules_null so it degrades to "not assessed - column not yet populated" rather than reading as "no health rule configured". Only a job that exists in a populated window with an empty/absent rule set counts as a confident "no coverage" signal. jobs is SCD2 (one row per change); this takes the latest row per (workspace_id, job_id) by change_time and excludes delete_time IS NOT NULL rows, since counting every change-history row would inflate the job count. job_id is unique only within a workspace, so grouping is by workspace_id + job_id. The "has a rule configured" test (CARDINALITY(health_rules) > 0) assumes health_rules is an array-typed column; if it is a scalar/string on your account, the query still runs and the *_null bucket captures it, but confirm the coverage split against your workspace's actual column type before trusting it.
-- system.lakeflow.jobs holds only defined Lakeflow Jobs; workloads launched as one-time SUBMIT_RUN or WORKFLOW_RUN never write to this dimension table, so those runs are absent from active_jobs entirely and their health-rule coverage is invisible here.
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
                THEN 1 ELSE 0 END)                            AS jobs_no_health_rule,
       -- status: worst-first band on health-rule coverage pct (field heuristic; :warn_coverage_pct / :crit_coverage_pct).
       CASE
         WHEN SUM(CASE WHEN health_rules IS NULL THEN 1 ELSE 0 END) = COUNT(*) THEN 'NOT_ASSESSED'
         WHEN 100.0 * SUM(CASE WHEN health_rules IS NOT NULL AND CARDINALITY(health_rules) > 0 THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*) - SUM(CASE WHEN health_rules IS NULL THEN 1 ELSE 0 END), 0) < :crit_coverage_pct THEN 'CRITICAL'
         WHEN 100.0 * SUM(CASE WHEN health_rules IS NOT NULL AND CARDINALITY(health_rules) > 0 THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*) - SUM(CASE WHEN health_rules IS NULL THEN 1 ELSE 0 END), 0) < :warn_coverage_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM latest_jobs
WHERE delete_time IS NULL
GROUP BY workspace_id
ORDER BY CASE status WHEN 'CRITICAL' THEN 1 WHEN 'NOT_ASSESSED' THEN 2 WHEN 'WARN' THEN 3 ELSE 4 END, active_jobs DESC
