-- query_id: cost_chargeback_by_identity
-- source: system.billing.usage
-- feeds: chargeback/tagging (identity-level rollup); untagged-but-attributable spend (identity present, tag absent); service-principal vs human-USER spend split; top human users ("pure users" leaderboard); per-WORKSPACE identity attribution
-- confidence: confirmed
-- caveats: identity_metadata is sparse/conditional and is replaced with '__REDACTED__' in FedRamp workspaces — engine must treat '__REDACTED__' and NULL as "identity unavailable", not a real principal. owned_by populates for SQL-warehouse usage only. identity_type is 'user' when run_as is an email, else 'service_principal' (SP app-id/name) — drop the run_as mask CASE (or build --no-redact) for an internal user leaderboard.
/* databricks_audit:cost_chargeback_by_identity */
SELECT usage_date, cloud, workspace_id, billing_origin_product,
       CASE
         WHEN identity_metadata.run_as IS NULL OR identity_metadata.run_as = '__REDACTED__' THEN 'unknown'
         WHEN identity_metadata.run_as LIKE '%@%' THEN 'user'
         ELSE 'service_principal'
       END                          AS identity_type,
       CASE
         WHEN identity_metadata.run_as IS NULL OR identity_metadata.run_as = '__REDACTED__' THEN identity_metadata.run_as
         WHEN identity_metadata.run_as LIKE '%@%' THEN concat(substr(identity_metadata.run_as, 1, 2), '****@****')
         WHEN identity_metadata.run_as RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN identity_metadata.run_as
         ELSE concat(substr(identity_metadata.run_as, 1, 2), '****')
       END                          AS identity_run_as,
       CASE
         WHEN identity_metadata.owned_by IS NULL OR identity_metadata.owned_by = '__REDACTED__' THEN identity_metadata.owned_by
         WHEN identity_metadata.owned_by LIKE '%@%' THEN concat(substr(identity_metadata.owned_by, 1, 2), '****@****')
         WHEN identity_metadata.owned_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN identity_metadata.owned_by
         ELSE concat(substr(identity_metadata.owned_by, 1, 2), '****')
       END                          AS identity_owned_by,
       CASE
         WHEN identity_metadata.created_by IS NULL OR identity_metadata.created_by = '__REDACTED__' THEN identity_metadata.created_by
         WHEN identity_metadata.created_by LIKE '%@%' THEN concat(substr(identity_metadata.created_by, 1, 2), '****@****')
         WHEN identity_metadata.created_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN identity_metadata.created_by
         ELSE concat(substr(identity_metadata.created_by, 1, 2), '****')
       END                          AS identity_created_by,
       SUM(usage_quantity) AS net_usage_quantity
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY usage_date, cloud, workspace_id, billing_origin_product,
         CASE
           WHEN identity_metadata.run_as IS NULL OR identity_metadata.run_as = '__REDACTED__' THEN 'unknown'
           WHEN identity_metadata.run_as LIKE '%@%' THEN 'user'
           ELSE 'service_principal'
         END,
         identity_metadata.run_as, identity_metadata.owned_by, identity_metadata.created_by
