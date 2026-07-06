-- query_id: lakeflow_pipeline_idle_tail_duration
-- source: system.lakeflow.pipeline_update_timeline (joined to pipelines, Public Preview)
-- feeds: DLT/Lakeflow pipeline tier + idle tail
-- confidence: needs_confirmation — verifier status `ok` on columns; bad_columns flag on the same struct access path.
-- NEEDS WORKSPACE CONFIRMATION: settings.continuous / settings.development dot-access (same struct-vs-map caveat as lakeflow_pipelines_inventory_tier).
-- caveats: Active update window is from period_start/end_time (confirmed). The idle tail itself (post-run cluster lingering) is NOT a lakeflow column — corroborate via serverless/DLT idle DBU in system.billing.usage joined by usage_metadata.dlt_pipeline_id. The plan's pipelines.clusterShutdown.delay is NOT in the documented schema and is deliberately not emitted.
/* databricks_audit:lakeflow_pipeline_idle_tail_duration */
-- NEEDS CONFIRMATION: settings.<key> dot-access is UNVERIFIED (struct vs map).
SELECT u.workspace_id, u.pipeline_id, p.pipeline_type, p.setting_continuous, p.setting_development,
       COUNT(DISTINCT u.update_id) AS updates,
       SUM(unix_timestamp(u.period_end_time) - unix_timestamp(u.period_start_time)) AS active_seconds_total
FROM system.lakeflow.pipeline_update_timeline u
LEFT JOIN (
  SELECT workspace_id, pipeline_id, pipeline_type,
         settings.continuous  AS setting_continuous,
         settings.development AS setting_development
  FROM system.lakeflow.pipelines
  QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, pipeline_id ORDER BY change_time DESC) = 1
) p
  ON u.workspace_id = p.workspace_id AND u.pipeline_id = p.pipeline_id
WHERE u.period_start_time >= date_add(current_date(), -30)
  AND u.period_end_time < date_trunc('DAY', current_timestamp())
  AND u.result_state IS NOT NULL
GROUP BY u.workspace_id, u.pipeline_id, p.pipeline_type, p.setting_continuous, p.setting_development
