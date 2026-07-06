-- query_id: compute_ai_gateway_usage
-- source: system.ai_gateway.usage
-- feeds: compute_ai_gateway_abuse (gov-6) — AI Gateway request volume, error-rate spikes, latency, token throughput, rate-limit/quota hits
-- confidence: needs_confirmation
-- caveats: system.ai_gateway.usage is empty unless AI Gateway is enabled on an endpoint — preflight skip-sentinels it and the finding degrades to not_assessed, never a fake zero. NEEDS WORKSPACE CONFIRMATION: the ai_gateway.usage column names are NOT verified against this workspace. This query assumes the documented shape — request_time (timestamp), workspace_id, endpoint_name, requester (the calling principal), status_code (HTTP), request_count, input_tokens, output_tokens, and an end-to-end latency column. The latency column name is uncertain (request_duration_ms assumed); status_code 429 is the assumed rate-limit/quota literal. PERCENTILE is intentionally avoided (the roadmap PERCENTILE landmine) — latency is summarised with the percentile_approx() fraction form 0.5/0.95, which is the correct Databricks signature. Every column is guarded downstream; an absent column degrades that metric to "unknown", not a finding. requester is an individual user or service principal, NOT a team — never relabel it. A 429/error row is an abuse/quota SIGNAL, not proof of misuse.
/* databricks_audit:compute_ai_gateway_usage */
SELECT
  CAST(g.request_time AS DATE)         AS usage_date,
  g.workspace_id                       AS workspace_id,
  CASE WHEN g.endpoint_name IS NULL THEN g.endpoint_name ELSE concat(substr(g.endpoint_name, 1, 2), '****') END AS endpoint_name,
  CASE
    WHEN g.requester IS NULL OR g.requester = '__REDACTED__' THEN g.requester
    WHEN g.requester LIKE '%@%' THEN concat(substr(g.requester, 1, 2), '****@****')
    WHEN g.requester RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN g.requester
    ELSE concat(substr(g.requester, 1, 2), '****')
  END                                  AS requester,
  SUM(g.request_count)                                                              AS total_requests,
  -- NEEDS WORKSPACE CONFIRMATION: 2xx == success; 429 == rate-limit/quota; other == error.
  SUM(CASE WHEN g.status_code BETWEEN 200 AND 299 THEN g.request_count ELSE 0 END)  AS success_requests,
  SUM(CASE WHEN g.status_code = 429 THEN g.request_count ELSE 0 END)                AS rate_limited_requests,
  SUM(CASE WHEN g.status_code IS NOT NULL
            AND NOT (g.status_code BETWEEN 200 AND 299)
            AND g.status_code <> 429 THEN g.request_count ELSE 0 END)               AS error_requests,
  -- Token throughput is its own magnitude, never blended with request counts.
  SUM(COALESCE(g.input_tokens, 0))                                                  AS input_tokens,
  SUM(COALESCE(g.output_tokens, 0))                                                 AS output_tokens,
  -- Latency via percentile_approx (fraction form — NOT the PERCENTILE(col, 95) landmine).
  -- NEEDS WORKSPACE CONFIRMATION: request_duration_ms is the assumed latency column.
  percentile_approx(g.request_duration_ms, 0.5)                                     AS p50_latency_ms,
  percentile_approx(g.request_duration_ms, 0.95)                                    AS p95_latency_ms,
  MAX(g.request_duration_ms)                                                        AS max_latency_ms
FROM system.ai_gateway.usage g
WHERE g.request_time >= dateadd(day, -:period_days, current_date())
  AND g.request_time <  current_date()
GROUP BY
  CAST(g.request_time AS DATE),
  g.workspace_id,
  g.endpoint_name,
  g.requester
