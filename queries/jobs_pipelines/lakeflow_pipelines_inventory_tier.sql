-- query_id: lakeflow_pipelines_inventory_tier
-- source: system.lakeflow.pipelines (Public Preview)
-- feeds: DLT/Lakeflow pipeline tier + idle tail
-- confidence: needs_confirmation — verifier status `ok` on table columns; bad_columns flag on the struct access path.
-- NEEDS WORKSPACE CONFIRMATION: the dot-access settings.serverless / settings.development / settings.continuous / settings.photon / settings.edition / settings.channel. The key names are confirmed, but whether settings is a STRUCT (dot-access) or a MAP (settings['serverless']) is UNVERIFIED.
-- caveats: pipelines is SCD2, Public Preview (may be empty/disabled). settings.edition here is the pipeline product edition (CORE/PRO/ADVANCED); the billing DLT tier surfaces separately in billing.product_features.dlt_tier.
/* databricks_audit:lakeflow_pipelines_inventory_tier */
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
