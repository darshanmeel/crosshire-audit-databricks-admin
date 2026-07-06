-- query_id:   classic_clusters_config_current
-- source:     system.compute.clusters
-- feeds:      oversized/right-sizing classic clusters; idle auto-stop config; cluster access-mode
--             posture (data_security_mode); DBR/runtime sprawl & EOL; compute-policy coverage
--             (policy_id NULL); init-script/Docker risk; spot-vs-on-demand mix (cloud attributes);
--             chargeback/tagging
-- confidence: confirmed
-- caveats:    Classic compute ONLY (all-purpose, jobs, Lakeflow SDP, pipeline-maintenance) — no
--             serverless, no SQL warehouses. NO runtime_engine/photon column (confirmed absent all
--             clouds). data_security_mode enum: USER_ISOLATION / SINGLE_USER / LEGACY_PASSTHROUGH /
--             LEGACY_SINGLE_USER / LEGACY_TABLE_ACL / NONE / null. worker_count NULL for autoscaling;
--             min/max_autoscale_workers NULL for fixed-size. aws/azure/gcp_attributes are STRUCTs
--             selected whole — only the cloud's own struct is populated; their subfields are
--             example-documented only (extracting a specific subfield is needs_confirmation —
--             see checklist). Regional.
/* databricks_audit:classic_clusters_config_current */
SELECT cluster_id,
       CASE WHEN cluster_name IS NULL THEN cluster_name ELSE concat(substr(cluster_name, 1, 2), '****') END AS cluster_name,
       CASE
         WHEN owned_by IS NULL OR owned_by = '__REDACTED__' THEN owned_by
         WHEN owned_by LIKE '%@%' THEN concat(substr(owned_by, 1, 2), '****@****')
         WHEN owned_by RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN owned_by
         ELSE concat(substr(owned_by, 1, 2), '****')
       END AS owned_by,
       driver_node_type, worker_node_type, worker_count,
       min_autoscale_workers, max_autoscale_workers, auto_termination_minutes, enable_elastic_disk,
       cluster_source, dbr_version, data_security_mode, policy_id, driver_instance_pool_id,
       worker_instance_pool_id, tags, init_scripts, aws_attributes, azure_attributes, gcp_attributes,
       create_time, delete_time, change_time, workspace_id, account_id
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY cluster_id ORDER BY change_time DESC) AS rn
  FROM system.compute.clusters
)
WHERE rn = 1 AND delete_time IS NULL
