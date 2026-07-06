-- query_id:   instance_events_idle_active
-- source:     system.compute.instance_events (Public Preview)
-- feeds:      spot-vs-on-demand cost mix (availability_type); instance idle-vs-active minutes
--             (INSTANCE_READY vs INSTANCE_PLACED); idle compute (classic instances)
-- confidence: needs_confirmation — table availability + derived idle-duration query shape
--             (NOT a column problem)
-- NEEDS WORKSPACE CONFIRMATION: system.compute.instance_events is PUBLIC PREVIEW (may be
--   empty/disabled — degrade by reason "preview table not populated"). All columns are confirmed.
--   The real finding (true idle-vs-active MINUTES) requires a per-instance windowed lead/lag over
--   event_time (READY vs PLACED) whose exact form is UNVERIFIED; this aggregate only summarizes
--   counts. No safer-fallback SQL given by the spec — spec SQL used verbatim as primary.
-- caveats:    PUBLIC PREVIEW — may be empty/disabled. state: INSTANCE_LAUNCHING /
--             INSTANCE_READY (idle) / INSTANCE_PLACED (in use) / INSTANCE_TERMINATED.
--             event_type: INSTANCE_LAUNCHING / STATE_TRANSITION. availability_type:
--             ON_DEMAND/SPOT (AWS/Azure), ON_DEMAND/PREEMPTIBLE (GCP). cluster_id populated
--             ONLY when state=INSTANCE_PLACED. Regional.
/* databricks_audit:instance_events_idle_active */
SELECT workspace_id, node_type, availability_type, state, event_type,
       COUNT(*) AS event_count,
       COUNT(DISTINCT instance_id) AS instance_count,
       MIN(event_time) AS first_event_time, MAX(event_time) AS last_event_time
FROM system.compute.instance_events
WHERE event_time >= current_timestamp() - INTERVAL :period_days DAYS
GROUP BY workspace_id, node_type, availability_type, state, event_type
