-- query_id: lakeflow_job_ownership_orphans
-- source: system.lakeflow.jobs
-- feeds: Job Health page — job ownership / creator-vs-run_as mismatch & orphan candidates (governance-1)
-- confidence: needs_confirmation
-- caveats: creator_user_name and run_as_user_name are "not populated before late Nov 2025" -> on short-history accounts they are NULL for every job. A NULL identity is UNATTRIBUTABLE (unknown owner), never a finding; FedRamp/redacted workspaces emit '__REDACTED__' which is likewise treated as unavailable, not a mismatch. We expose jobs_creator_null / jobs_runas_null so a fully-NULL column degrades to "not assessed" rather than reading every job as orphaned. A confident "ownership mismatch" requires BOTH identities populated AND non-redacted AND different (creator != run_as) — a legitimate but worth-reviewing handoff/service-principal pattern. jobs is SCD2 -> latest row per (workspace_id, job_id) by change_time, then delete_time IS NULL (must-fix: dedupe change-history before counting). job_id unique only within a workspace -> partition includes workspace_id. This is a governance posture signal, not a cost figure.
/* databricks_audit:lakeflow_job_ownership_orphans */
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
                THEN 1 ELSE 0 END)                                AS jobs_orphan_runas_unknown
FROM norm
GROUP BY workspace_id
