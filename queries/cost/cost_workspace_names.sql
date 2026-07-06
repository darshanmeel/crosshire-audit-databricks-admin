-- query_id: cost_workspace_names
-- source: system.access.workspaces_latest
-- feeds: workspace_id -> name lookup, so every per-workspace cut (cost, identity, provenance) shows "dev / uat / prod" instead of an opaque numeric id
-- confidence: confirmed
-- caveats: DELIBERATELY a separate tiny lookup — NOT joined into billing.usage — so that if system.access.workspaces_latest is not enabled (or errors), only the NAME resolution is lost and the per-workspace cost data (keyed on workspace_id) is unaffected; the join happens at build time and falls back to the numeric workspace_id. `status` distinguishes active vs deleted workspaces. One row per workspace (latest snapshot).
/* databricks_audit:cost_workspace_names */
SELECT workspace_id, workspace_name, status
FROM system.access.workspaces_latest
