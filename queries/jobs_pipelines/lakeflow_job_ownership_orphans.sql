-- query_id: lakeflow_job_ownership_orphans
-- title: Job ownership mismatches and orphan run-as candidates
-- domain: jobs_pipelines   tier: standard
-- reads: system.lakeflow.jobs
-- requires: SELECT on system.lakeflow; GA (system.lakeflow.jobs is generally available; creator_user_name/run_as_user_name were added late Nov 2025)
-- params: :warn_orphan_jobs (default 5) combined mismatch+orphan job count in a workspace that flags WARN; :crit_orphan_jobs (default 20) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: creator_user_name and run_as_user_name are not populated before late Nov 2025, and FedRAMP/redacted workspaces emit '__REDACTED__' for masked identities; both cases are normalized to NULL before counting so they never register as a real owner or a real mismatch.
-- read_this: One row = a workspace. The columns that matter are jobs_owner_mismatch (creator and run-as identity both known and different - a handoff or service-principal pattern worth a look) and jobs_orphan_runas_unknown (run-as identity unknown while the creator is known - nobody clearly owns execution).
-- healthy: jobs_owner_mismatch and jobs_orphan_runas_unknown both low relative to active_jobs, and jobs_creator_null/jobs_runas_null near 0 so the picture is trustworthy - field heuristic; tune :warn_orphan_jobs for your account.
-- investigate_if: (jobs_owner_mismatch + jobs_orphan_runas_unknown) at/above :warn_orphan_jobs (WARN) or :crit_orphan_jobs (CRITICAL) - field heuristic; this is a governance posture signal, not a cost figure.
-- actions: 1) list the flagged jobs and confirm each mismatch/orphan is an intentional handoff or service-principal run-as (free); 2) require run_as to be set explicitly (not inherited) in your job-creation template (config); 3) n/a - this finding does not itself justify new spend.
-- next: lakeflow_health_rule_coverage (for the related governance-coverage picture), lakeflow_stale_zombie_jobs (orphaned jobs are often also stale)
-- caveats: creator_user_name and run_as_user_name are not populated before late Nov 2025, so on a short-history account they are NULL for every job. A NULL identity is unattributable (unknown owner), never treated as a finding; FedRAMP/redacted workspaces emit '__REDACTED__', which is likewise treated as unavailable, not a mismatch. jobs_creator_null / jobs_runas_null are reported separately so a fully-NULL column degrades to "not assessed" rather than reading every job as orphaned. A confident "ownership mismatch" requires BOTH identities populated AND non-redacted AND different (creator != run_as) - a legitimate but worth-reviewing handoff/service-principal pattern. jobs is SCD2 (one row per change); this takes the latest row per (workspace_id, job_id) by change_time, then excludes delete_time IS NOT NULL rows (must dedupe change-history before counting, or jobs inflate). job_id is unique only within a workspace, so the partition includes workspace_id. This is a governance posture signal, not a cost figure.
-- system.lakeflow.jobs is a definition table that one-time SUBMIT_RUN/WORKFLOW_RUN executions skip entirely, so jobs run only via submit/workflow runs never appear here and are invisible to this ownership/orphan assessment.
WITH latest_jobs AS (
  SELECT workspace_id, job_id, name, creator_user_name, run_as_user_name, delete_time
  FROM system.lakeflow.jobs
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY workspace_id, job_id ORDER BY change_time DESC
  ) = 1
),
-- normalise unavailable / redacted identity placeholders to NULL so they are never
-- counted as a real owner or a real mismatch.
norm AS (
  SELECT workspace_id, job_id, name,
         CASE WHEN creator_user_name IS NULL
                OR trim(creator_user_name) = ''
                OR upper(creator_user_name) = '__REDACTED__'
              THEN NULL ELSE creator_user_name END AS creator_user_name,
         CASE WHEN run_as_user_name IS NULL
                OR trim(run_as_user_name) = ''
                OR upper(run_as_user_name) = '__REDACTED__'
              THEN NULL ELSE run_as_user_name END  AS run_as_user_name
  FROM latest_jobs
  WHERE delete_time IS NULL
)
SELECT workspace_id,
       COUNT(*) AS active_jobs,
       SUM(CASE WHEN creator_user_name IS NULL THEN 1 ELSE 0 END) AS jobs_creator_null,
       SUM(CASE WHEN run_as_user_name  IS NULL THEN 1 ELSE 0 END) AS jobs_runas_null,
       -- confident mismatch: both identities known & different (handoff / SP run-as)
       SUM(CASE WHEN creator_user_name IS NOT NULL
                 AND run_as_user_name IS NOT NULL
                 AND creator_user_name <> run_as_user_name
                THEN 1 ELSE 0 END)                                AS jobs_owner_mismatch,
       -- orphan candidate: run-as identity unknown but creator known (no one clearly runs it)
       SUM(CASE WHEN run_as_user_name IS NULL AND creator_user_name IS NOT NULL
                THEN 1 ELSE 0 END)                                AS jobs_orphan_runas_unknown,
       -- status: worst-first band on combined ownership-risk job count (field heuristic;
       -- :warn_orphan_jobs / :crit_orphan_jobs).
       CASE
         WHEN COUNT(*) = SUM(CASE WHEN creator_user_name IS NULL THEN 1 ELSE 0 END) THEN 'NOT_ASSESSED'
         WHEN (SUM(CASE WHEN creator_user_name IS NOT NULL AND run_as_user_name IS NOT NULL AND creator_user_name <> run_as_user_name THEN 1 ELSE 0 END)
             + SUM(CASE WHEN run_as_user_name IS NULL AND creator_user_name IS NOT NULL THEN 1 ELSE 0 END)) >= :crit_orphan_jobs THEN 'CRITICAL'
         WHEN (SUM(CASE WHEN creator_user_name IS NOT NULL AND run_as_user_name IS NOT NULL AND creator_user_name <> run_as_user_name THEN 1 ELSE 0 END)
             + SUM(CASE WHEN run_as_user_name IS NULL AND creator_user_name IS NOT NULL THEN 1 ELSE 0 END)) >= :warn_orphan_jobs THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM norm
GROUP BY workspace_id
ORDER BY (jobs_owner_mismatch + jobs_orphan_runas_unknown) DESC
