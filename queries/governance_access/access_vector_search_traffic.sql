-- query_id: access_vector_search_traffic
-- title: Vector Search query and scan traffic by endpoint
-- domain: governance_access   tier: standard
-- reads: system.access.audit
-- requires: SELECT on system.access; Public Preview
-- params: :period_days (default 30) rolling window in days.
-- confidence: confirmed
-- confidence_note: service_name='vectorSearch' and the query/scan action_name set (queryVectorIndex, queryVectorIndexNextPage, queryVectorIndexRouteOptimized, scanVectorIndex, scanVectorIndexRouteOptimized) are confirmed against Databricks' documentation on unused Vector Search endpoints.
-- read_this: One row = an endpoint x action x day, with how many query/scan events it received. The column that matters is event_count - join this against your own billing data to tell a provisioned-but-unqueried endpoint (bills spend, zero rows here) from a genuinely idle one.
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: cost_vector_search_spend (join this against spend to find endpoints that bill but never show up here), compute_serving_dormant_endpoints (the general serving-endpoint idle-detection sibling)
-- caveats: service_name='vectorSearch' and the query/scan action_name set (queryVectorIndex, queryVectorIndexNextPage, queryVectorIndexRouteOptimized, scanVectorIndex, scanVectorIndexRouteOptimized) are confirmed against Databricks' documentation on unused Vector Search endpoints. The endpoint is identified via request_params['endpoint_name']. An endpoint that bills spend but has no row here is provisioned-but-unqueried - a retire candidate - but you need to join this against your own billing data; this query alone only tells you what was queried, not what was billed. If this source has no rows at all, idle status cannot be assessed from it - treat that as visibility-only, never assume idle.
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
ORDER BY event_date DESC, endpoint_name, action_name
