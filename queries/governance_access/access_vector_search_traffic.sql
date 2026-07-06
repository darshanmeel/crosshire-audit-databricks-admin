-- query_id: access_vector_search_traffic
-- source: system.access.audit
-- feeds: Vector Search idle-endpoint detection (which endpoints received query/scan traffic in the window) — joined in-engine to cost_vector_search_spend
-- confidence: confirmed
-- caveats: service_name='vectorSearch' and the query/scan action_name set (queryVectorIndex, queryVectorIndexNextPage, queryVectorIndexRouteOptimized, scanVectorIndex, scanVectorIndexRouteOptimized) are CONFIRMED in docs (vector-search/vector-search-unused-endpoints). The endpoint is identified via request_params['endpoint_name']. An endpoint that BILLS spend (cost_vector_search_spend) but has NO row here is provisioned-but-unqueried = a retire candidate. Absence of this source means idle cannot be assessed — the finding then stays visibility-only (never assumes idle).
/* databricks_audit:access_vector_search_traffic */
SELECT event_date,
       action_name,
       CASE WHEN request_params['endpoint_name'] IS NULL THEN request_params['endpoint_name'] ELSE concat(substr(request_params['endpoint_name'], 1, 2), '****') END AS endpoint_name,
       COUNT(*) AS event_count
FROM system.access.audit
WHERE service_name = 'vectorSearch'
  AND action_name IN (
        'queryVectorIndex', 'queryVectorIndexNextPage',
        'queryVectorIndexRouteOptimized', 'scanVectorIndex',
        'scanVectorIndexRouteOptimized')
  AND event_date >= dateadd(day, -:period_days, current_date())
  AND event_date < current_date()
GROUP BY event_date, action_name, request_params['endpoint_name']
