-- query_id: lakeflow_pipeline_idle_tail_duration
-- source: system.lakeflow.pipeline_update_timeline (joined to pipelines, Public Preview)
-- feeds: DLT/Lakeflow pipeline tier + idle tail
-- confidence: needs_confirmation — verifier status `ok` on columns; bad_columns flag on the same struct access path.
-- NEEDS WORKSPACE CONFIRMATION: settings.continuous / settings.development dot-access (same struct-vs-map caveat as lakeflow_pipelines_inventory_tier).
-- caveats: Active update window is from period_start/end_time (confirmed). The idle tail itself (post-run cluster lingering) is NOT a lakeflow column — corroborate via serverless/DLT idle DBU in system.billing.usage joined by usage_metadata.dlt_pipeline_id. The plan's pipelines.clusterShutdown.delay is NOT in the documented schema and is deliberately not emitted.
-- net_dbus is exact billed DBUs (usage_unit='DBU'); est_usd_list is a LIST-PRICE ESTIMATE
--   (usage_quantity x list_prices.pricing.default) -- NOT the negotiated invoice rate (not in any
--   system table) and excludes cloud infra/egress $. Directional, needs_confirmation.
-- Cost is attributed by billing ID (workspace_id + dlt_pipeline_id) over the window (per-pipeline),
--   not per update/event. Cost rollup is pre-aggregated then LEFT JOINed, so finding rows are never multiplied.
/* databricks_audit:lakeflow_pipeline_idle_tail_duration */
-- NEEDS CONFIRMATION: settings.<key> dot-access is UNVERIFIED (struct vs map).
WITH price AS (
  SELECT sku_name, cloud, usage_unit, price_start_time, price_end_time,
         CAST(pricing.default AS DOUBLE) AS list_rate
  FROM system.billing.list_prices
),
cost_rollup AS (
  SELECT u.workspace_id,
         u.usage_metadata.dlt_pipeline_id AS dlt_pipeline_id,
         SUM(u.usage_quantity)                            AS net_dbus,
         SUM(u.usage_quantity * COALESCE(p.list_rate, 0)) AS est_usd_list
  FROM system.billing.usage u
  LEFT JOIN price p
    ON u.sku_name = p.sku_name AND u.cloud = p.cloud AND u.usage_unit = p.usage_unit
   AND u.usage_end_time >= p.price_start_time
   AND (p.price_end_time IS NULL OR u.usage_end_time < p.price_end_time)
  WHERE upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.dlt_pipeline_id IS NOT NULL
    AND u.usage_date >= date_add(current_date(), -30)
    AND u.usage_date <  current_date()
  GROUP BY u.workspace_id, u.usage_metadata.dlt_pipeline_id
)
SELECT u.workspace_id, u.pipeline_id, p.pipeline_type, p.setting_continuous, p.setting_development,
       COUNT(DISTINCT u.update_id) AS updates,
       SUM(unix_timestamp(u.period_end_time) - unix_timestamp(u.period_start_time)) AS active_seconds_total,
       COALESCE(MAX(cr.net_dbus), 0)     AS net_dbus,
       COALESCE(MAX(cr.est_usd_list), 0) AS est_usd_list
FROM system.lakeflow.pipeline_update_timeline u
LEFT JOIN (
  SELECT workspace_id, pipeline_id, pipeline_type,
         settings.continuous  AS setting_continuous,
         settings.development AS setting_development
  FROM system.lakeflow.pipelines
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, pipeline_id ORDER BY change_time DESC) = 1
) p
  ON u.workspace_id = p.workspace_id AND u.pipeline_id = p.pipeline_id
LEFT JOIN cost_rollup cr
  ON u.workspace_id = cr.workspace_id AND u.pipeline_id = cr.dlt_pipeline_id
WHERE u.period_start_time >= date_add(current_date(), -30)
  AND u.period_end_time < date_trunc('DAY', current_timestamp())
  AND u.result_state IS NOT NULL
GROUP BY u.workspace_id, u.pipeline_id, p.pipeline_type, p.setting_continuous, p.setting_development