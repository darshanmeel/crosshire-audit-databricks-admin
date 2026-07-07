-- query_id: lakeflow_pipeline_cost
-- title: Per-pipeline DBU cost and update/refresh volume
-- domain: jobs_pipelines   tier: deep
-- reads: system.billing.usage, system.billing.list_prices, system.lakeflow.pipelines, system.lakeflow.pipeline_update_timeline
-- requires: SELECT on system.billing, system.lakeflow; GA (system.billing.usage/list_prices); Public Preview (system.lakeflow.pipelines and pipeline_update_timeline - a missing/disabled table degrades names/updates to NULL, never the DBU attribution)
-- params: :period_days (default 30) rolling window in days; :warn_pipeline_dbus (default 500) net pipeline DBUs in the window that flags WARN; :crit_pipeline_dbus (default 2000) that flags CRITICAL
-- confidence: needs_confirmation
-- confidence_note: the list_rate CAST path (pricing.effective_list.default) is unverified, so net_list_cost is a directional list-price estimate, never a billed dollar figure; confirm the struct path against your workspace's system.billing.list_prices schema.
-- read_this: One row = a pipeline. The column that matters is net_pipeline_dbus - net DBUs billed to that pipeline in the window; net_maintenance_dbus is the housekeeping share of that total, broken out separately; updates/active_seconds_total are the over-refresh signal (many short updates can mean the pipeline is triggered more often than the data actually changes).
-- healthy: net_pipeline_dbus below :warn_pipeline_dbus for the window, with maintenance a small share of the total - field heuristic; tune :warn_pipeline_dbus for your account.
-- investigate_if: net_pipeline_dbus at/above :warn_pipeline_dbus (WARN) or :crit_pipeline_dbus (CRITICAL) - field heuristic; also look at updates vs active_seconds_total for over-refresh.
-- actions: 1) check the pipeline's trigger interval against how often the source data actually changes and space it out if it is over-refreshing (free); 2) switch a continuously-triggered pipeline to a scheduled/triggered pipeline if continuous freshness is not required (config); 3) if the pipeline is correctly sized and still expensive, revisit serverless/Photon settings or move it to a cheaper SKU tier (spend).
-- next: lakeflow_pipeline_idle_tail_duration (for cluster lingering after the pipeline's active window), lakeflow_pipeline_update_failures_retries (for how much of that DBU spend is retries)
-- caveats: PER-PIPELINE DBUs = net DBUs billed on system.billing.usage rows carrying usage_metadata.dlt_pipeline_id, attributed on (workspace_id, dlt_pipeline_id). usage_metadata also carries dlt_update_id and dlt_maintenance_id; maintenance DBUs (dlt_maintenance_id IS NOT NULL) are summed into a SEPARATE net_maintenance_dbus column so housekeeping is not blamed on pipeline logic. usage_quantity is summed across ALL record_types (ORIGINAL/RETRACTION/RESTATEMENT already net) and filtered to upper(usage_unit)='DBU', so bytes/hours/tokens never blend into the DBU total. list_rate (pricing.effective_list.default) is a LIST estimate only and the CAST path is UNVERIFIED - treat net_list_cost as an estimate before your discount, never a billed dollar; the price window is open-interval (price_end_time NULL = currently effective). dlt_pipeline_id is unique only WITHIN a workspace, so every join/group here is on (workspace_id, pipeline_id), never pipeline_id alone. pipelines is SCD2, so this takes the latest row via QUALIFY ROW_NUMBER() OVER (PARTITION BY workspace_id, pipeline_id ORDER BY change_time DESC) = 1 for names, not ids. pipeline_update_timeline gives the update count and active-second proxy for the over-refresh signal; result_state IS NOT NULL marks an update's end row. system.lakeflow.pipelines and pipeline_update_timeline are Public Preview - a missing table degrades the names/update columns to NULL via LEFT JOIN, never dropping the DBU attribution itself.
WITH pipe_dbus AS (
  -- DBUs billed to each pipeline over the window. Net across ALL record_types; DBU only.
  -- Split maintenance DBUs out via dlt_maintenance_id so they are reported separately.
  SELECT workspace_id,
         usage_metadata.dlt_pipeline_id AS pipeline_id,
         SUM(usage_quantity) AS net_pipeline_dbus,
         SUM(CASE WHEN usage_metadata.dlt_maintenance_id IS NOT NULL
                  THEN usage_quantity ELSE 0 END) AS net_maintenance_dbus
  FROM system.billing.usage
  WHERE usage_date >= dateadd(day, -:period_days, current_date())
    AND usage_date < current_date()
    AND upper(usage_unit) = 'DBU'
    AND usage_metadata.dlt_pipeline_id IS NOT NULL
  GROUP BY workspace_id, usage_metadata.dlt_pipeline_id
),
pipe_list AS (
  -- LIST-$ estimate only (pre-discount, CAST-unverified): SUM(usage_quantity * list_rate)
  -- per pipeline. Apply your negotiated discount on top of this; never a billed dollar.
  SELECT u.workspace_id,
         u.usage_metadata.dlt_pipeline_id AS pipeline_id,
         MAX(lp.currency_code) AS currency_code,
         SUM(u.usage_quantity * lp.list_rate) AS net_list_cost
  FROM system.billing.usage u
  LEFT JOIN (
    SELECT sku_name, cloud, currency_code, usage_unit, price_start_time, price_end_time,
           CAST(pricing.effective_list.default AS DOUBLE) AS list_rate   -- <-- UNVERIFIED path
    FROM system.billing.list_prices
  ) lp
    ON u.sku_name = lp.sku_name
   AND u.cloud    = lp.cloud
   AND u.usage_end_time >= lp.price_start_time
   AND (lp.price_end_time IS NULL OR u.usage_end_time < lp.price_end_time)
  WHERE u.usage_date >= dateadd(day, -:period_days, current_date())
    AND u.usage_date < current_date()
    AND upper(u.usage_unit) = 'DBU'
    AND u.usage_metadata.dlt_pipeline_id IS NOT NULL
  GROUP BY u.workspace_id, u.usage_metadata.dlt_pipeline_id
),
pipe_meta AS (
  -- SCD2 latest row per (workspace_id, pipeline_id): names-not-ids + type.
  SELECT workspace_id, pipeline_id, name AS pipeline_name, pipeline_type
  FROM system.lakeflow.pipelines
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY workspace_id, pipeline_id ORDER BY change_time DESC
  ) = 1
),
pipe_updates AS (
  -- Over-refresh signal: distinct updates + total active seconds per pipeline.
  SELECT workspace_id, pipeline_id,
         COUNT(DISTINCT update_id) AS updates,
         SUM(unix_timestamp(period_end_time) - unix_timestamp(period_start_time)) AS active_seconds_total
  FROM system.lakeflow.pipeline_update_timeline
  WHERE period_start_time >= dateadd(day, -:period_days, current_date())
    AND period_end_time < date_trunc('DAY', current_timestamp())
    AND result_state IS NOT NULL   -- update end row only
  GROUP BY workspace_id, pipeline_id
)
SELECT d.workspace_id,
       d.pipeline_id,
       CASE WHEN m.pipeline_name IS NULL THEN m.pipeline_name ELSE concat(substr(m.pipeline_name, 1, 2), '****') END AS pipeline_name,
       m.pipeline_type,
       d.net_pipeline_dbus,
       d.net_maintenance_dbus,
       l.currency_code,
       l.net_list_cost,
       COALESCE(up.updates, 0)              AS updates,
       COALESCE(up.active_seconds_total, 0) AS active_seconds_total,
       -- status: worst-first band on net pipeline DBUs in the window (field heuristic; :warn_pipeline_dbus / :crit_pipeline_dbus).
       CASE
         WHEN d.net_pipeline_dbus >= :crit_pipeline_dbus THEN 'CRITICAL'
         WHEN d.net_pipeline_dbus >= :warn_pipeline_dbus THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM pipe_dbus d
LEFT JOIN pipe_list l
  ON d.workspace_id = l.workspace_id AND d.pipeline_id = l.pipeline_id
LEFT JOIN pipe_meta m
  ON d.workspace_id = m.workspace_id AND d.pipeline_id = m.pipeline_id
LEFT JOIN pipe_updates up
  ON d.workspace_id = up.workspace_id AND d.pipeline_id = up.pipeline_id
WHERE d.net_pipeline_dbus > 0
ORDER BY d.net_pipeline_dbus DESC
