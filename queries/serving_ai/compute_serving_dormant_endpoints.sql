-- query_id: compute_serving_dormant_endpoints
-- source: system.serving.served_entities
-- feeds: compute_serving_dormant_endpoints (gov-5 dormant arm) — endpoints/served-entities with no request traffic in the window
-- confidence: needs_confirmation
-- caveats: system.serving.* is empty unless Model Serving is enabled/in use — preflight skip-sentinels it and the finding degrades to not_assessed (never a fake zero "all endpoints dormant"). DORMANT must-fix: served_entities is the DIMENSION and is change-history, so it is deduped to the latest row per (workspace_id, endpoint_id, served_entity_id) by change_time DESC FIRST; endpoint_usage is then LEFT JOINed as a per-entity rollup so an entity with NO usage row keeps last_request_date = NULL and total_requests = 0. A NULL last-usage means "no traffic observed", which is the dormant signal — it is NOT treated as "recently active". last_request_date NULL can also mean the request simply predates the window or that usage retention is shorter than the dimension; the finding labels dormant as "no requests in the last N days", not "never used", and discloses the window. NEEDS WORKSPACE CONFIRMATION: endpoint_usage.request_time / request_count column names and that endpoint_creator/created flags exist on served_entities — newly-created endpoints inside the window should not read as dormant, so the latest change_time is carried out as a recency floor and the finding excludes entities whose only change is newer than the window start.
/* databricks_audit:compute_serving_dormant_endpoints */
WITH entities AS (
  -- served_entities is change-history; collapse to the latest config row per entity.
  SELECT
    workspace_id,
    endpoint_id,
    endpoint_name,
    served_entity_id,
    served_entity_name,
    entity_type,
    entity_name,
    entity_version,
    latest_change_time
  FROM (
    SELECT
      se.workspace_id,
      se.endpoint_id,
      se.endpoint_name,
      se.served_entity_id,
      se.served_entity_name,
      se.entity_type,
      se.entity_name,
      se.entity_version,
      MAX(se.change_time) OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
      ) AS latest_change_time,
      ROW_NUMBER() OVER (
        PARTITION BY se.workspace_id, se.endpoint_id, se.served_entity_id
        ORDER BY se.change_time DESC
      ) AS _rn
    FROM system.serving.served_entities se
  )
  WHERE _rn = 1
),
usage_rollup AS (
  -- Per-entity traffic inside the window. Entities with no traffic never appear here,
  -- so the LEFT JOIN below leaves their last_request_date NULL (the dormant signal).
  SELECT
    eu.workspace_id,
    eu.endpoint_id,
    eu.served_entity_id,
    SUM(eu.request_count)          AS total_requests,
    MAX(CAST(eu.request_time AS DATE)) AS last_request_date
  FROM system.serving.endpoint_usage eu
  WHERE eu.request_time >= dateadd(day, -:period_days, current_date())
    AND eu.request_time <  current_date()
  GROUP BY eu.workspace_id, eu.endpoint_id, eu.served_entity_id
)
SELECT
  ent.workspace_id                            AS workspace_id,
  ent.endpoint_id                             AS endpoint_id,
  CASE WHEN ent.endpoint_name IS NULL THEN ent.endpoint_name ELSE concat(substr(ent.endpoint_name, 1, 2), '****') END AS endpoint_name,
  ent.served_entity_id                        AS served_entity_id,
  CASE WHEN ent.served_entity_name IS NULL THEN ent.served_entity_name ELSE concat(substr(ent.served_entity_name, 1, 2), '****') END AS served_entity_name,
  ent.entity_type                             AS entity_type,
  ent.entity_name                             AS entity_name,
  ent.latest_change_time                      AS latest_change_time,
  CAST(ent.latest_change_time AS DATE)        AS latest_change_date,
  COALESCE(ur.total_requests, 0)              AS total_requests,
  ur.last_request_date                        AS last_request_date
FROM entities ent
LEFT JOIN usage_rollup ur
  ON  ent.workspace_id     = ur.workspace_id
  AND ent.endpoint_id      = ur.endpoint_id
  AND ent.served_entity_id = ur.served_entity_id
