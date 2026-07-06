-- query_id:   instance_pools_idle_capacity
-- source:     system.compute.instance_pools (Public Preview)
-- feeds:      instance-pool idle waste (min_idle_instances × node cost); pool right-sizing
--             (max_capacity); idle auto-termination config; Docker/preload risk
--             (preloaded_docker_images); tagging
-- confidence: needs_confirmation — table is Public Preview (NOT a column problem)
-- NEEDS WORKSPACE CONFIRMATION: system.compute.instance_pools is PUBLIC PREVIEW (may be
--   empty/disabled — degrade by reason "preview table not populated"). All columns are confirmed.
--   No safer-fallback SQL given by the spec — spec SQL used verbatim as primary.
-- caveats:    SCD: latest per instance_pool_id. min_idle_instances/max_capacity are bigint.
--             disk_spec/aws/azure/gcp_attributes are STRUCTs selected whole — subfields are
--             example-documented only (selecting a specific subfield is needs_confirmation).
--             Idle-waste dollarization needs node cost which is NOT in compute tables (join to
--             billing.usage / list_prices, out of this domain). Regional.
/* databricks_audit:instance_pools_idle_capacity */
SELECT instance_pool_id,
       CASE WHEN instance_pool_name IS NULL THEN instance_pool_name ELSE concat(substr(instance_pool_name, 1, 2), '****') END AS instance_pool_name,
       node_type, min_idle_instances, max_capacity,
       idle_instance_autotermination_minutes, enable_elastic_disk, preloaded_spark_version,
       preloaded_docker_images, tags, aws_attributes, azure_attributes, gcp_attributes, disk_spec,
       create_time, delete_time, change_time, workspace_id, account_id
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY instance_pool_id ORDER BY change_time DESC) AS rn
  FROM system.compute.instance_pools
)
WHERE rn = 1 AND delete_time IS NULL
