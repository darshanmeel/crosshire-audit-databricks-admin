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
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID (usage_metadata.instance_pool_id) over the window (per-pool),
--   not per event. Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never
--   multiplied. This finding is a config SNAPSHOT with no time window of its own, so the cost
--   window uses a :period_days param (default via the caller); it is the pool's compute spend, not
--   a measure of idle-only waste. Pools are billed via the clusters that use them, tagged with
--   instance_pool_id on billing.usage. instance_pool_id is a globally-unique GUID; rollup is keyed
--   on workspace_id + instance_pool_id (both present here) to keep the LEFT JOIN strictly 1:1.
/* databricks_audit:instance_pools_idle_capacity */
WITH price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  SELECT u.workspace_id,
         u.usage_metadata.instance_pool_id AS instance_pool_id,
         SUM(u.usage_quantity)                            AS net_dbus,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.instance_pool_id IS NOT NULL
    AND u.usage_date >= date_add(current_date(), -CAST(:period_days AS INT))
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.instance_pool_id
)
SELECT p.instance_pool_id,
       CASE WHEN p.instance_pool_name IS NULL THEN p.instance_pool_name ELSE concat(substr(p.instance_pool_name, 1, 2), '****') END AS instance_pool_name,
       p.node_type, p.min_idle_instances, p.max_capacity,
       p.idle_instance_autotermination_minutes, p.enable_elastic_disk, p.preloaded_spark_version,
       p.preloaded_docker_images, p.tags, p.aws_attributes, p.azure_attributes, p.gcp_attributes, p.disk_spec,
       p.create_time, p.delete_time, p.change_time, p.workspace_id, p.account_id,
       COALESCE(cr.net_dbus, 0)     AS net_dbus,
       COALESCE(cr.est_usd_list, 0) AS est_usd_list
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY instance_pool_id ORDER BY change_time DESC) AS rn
  FROM system.compute.instance_pools
) p
LEFT JOIN cost_rollup cr
  ON cr.workspace_id = p.workspace_id
 AND cr.instance_pool_id = p.instance_pool_id
WHERE p.rn = 1 AND p.delete_time IS NULL