-- query_id: cost_restatement_trust_metric
-- source: system.billing.usage
-- feeds: % restated (record_type); no-double-counting trust guarantee; data freshness/lag note
-- confidence: confirmed
-- caveats: Produces the "% of usage later restated" trust metric (retracted_abs + restatement vs original) and proves the net does not double-count corrections. ingestion_date (distinct from usage_date) supports incremental loads and the freshness caveat.
/* databricks_audit:cost_restatement_trust_metric */
SELECT cloud,
       SUM(usage_quantity) AS net_usage_quantity,
       SUM(CASE WHEN record_type = 'ORIGINAL'    THEN usage_quantity      ELSE 0 END) AS original_usage_quantity,
       SUM(CASE WHEN record_type = 'RETRACTION'  THEN ABS(usage_quantity) ELSE 0 END) AS retracted_abs_quantity,
       SUM(CASE WHEN record_type = 'RESTATEMENT' THEN usage_quantity      ELSE 0 END) AS restatement_usage_quantity,
       MAX(ingestion_date) AS max_ingestion_date
FROM system.billing.usage
WHERE usage_date >= dateadd(day, -:period_days, current_date())
  AND usage_date < current_date()
GROUP BY cloud
