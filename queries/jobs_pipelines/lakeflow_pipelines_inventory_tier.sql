-- query_id: lakeflow_pipelines_inventory_tier
-- title: Pipeline inventory by type, edition, and key settings
-- domain: jobs_pipelines   tier: lite
-- reads: system.lakeflow.pipelines
-- requires: SELECT on system.lakeflow; Public Preview (system.lakeflow.pipelines)
-- empty_if: schema_not_enabled, preview_unavailable
-- params: none - this is a point-in-time inventory with no tunable thresholds.
-- confidence: needs_confirmation
-- confidence_note: whether settings is a STRUCT (dot-access, used here) or a MAP (settings['key']) on your account is unverified; confirm before trusting the setting_* columns.
-- read_this: One row = a distinct combination of workspace, pipeline_type, and key settings, with pipelines as the count. Use this to see your pipeline mix (serverless vs classic, continuous vs triggered, dev vs prod) before drilling into a cost or idle-tail finding.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: lakeflow_pipeline_cost (drill into DBU cost per pipeline), lakeflow_pipeline_idle_tail_duration (drill into idle-tail exposure per pipeline)
-- caveats: pipelines is Public Preview and SCD2 - this table may be empty/disabled on your account, and the query takes the latest row per (workspace_id, pipeline_id) by change_time. setting_edition here is the pipeline product edition (CORE/PRO/ADVANCED); the billing DLT tier is a separate concept that surfaces in billing.product_features.dlt_tier, not here. The settings.serverless / settings.development / settings.continuous / settings.photon / settings.edition / settings.channel dot-access assumes settings is a STRUCT - the key names are confirmed, but whether it is a STRUCT (dot-access) or a MAP (settings['key']) is unverified on your account.
-- NEEDS CONFIRMATION: settings.<key> dot-access vs settings['<key>'] map-access is UNVERIFIED.
WITH latest_pipelines AS (
  SELECT workspace_id, pipeline_id, pipeline_type, name, created_by, run_as, settings, delete_time,
         settings.serverless  AS setting_serverless,
         settings.development AS setting_development,
         settings.continuous  AS setting_continuous,
         settings.photon      AS setting_photon,
         settings.edition     AS setting_edition,
         settings.channel     AS setting_channel
  FROM system.lakeflow.pipelines
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, pipeline_id ORDER BY change_time DESC) = 1
)
SELECT workspace_id, pipeline_type, setting_serverless, setting_development,
       setting_continuous, setting_edition,
       COUNT(*) AS pipelines
FROM latest_pipelines
WHERE delete_time IS NULL
GROUP BY workspace_id, pipeline_type, setting_serverless, setting_development, setting_continuous, setting_edition
ORDER BY workspace_id, pipeline_type
