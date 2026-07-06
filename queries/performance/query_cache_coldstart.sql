-- query_id: query_cache_coldstart
-- source: system.query.history
-- feeds: cache/cold-start (read_io_cache_percent)
-- confidence: confirmed
-- caveats: Two distinct cache signals: from_result_cache (result cache, boolean) vs read_io_cache_percent (disk/IO cache) — NOT one combined percentage. waiting_for_compute_duration_ms = cold-start latency; compilation_duration_ms = metadata/optimizer-bound. NULL behavior of read_io_cache_percent for non-scan statements is undocumented (see checklist). Regional.
/* databricks_audit:query_cache_coldstart */
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       COUNT(*) AS query_count,
       SUM(CASE WHEN from_result_cache THEN 1 ELSE 0 END) AS result_cache_hit_count,
       AVG(read_io_cache_percent) AS read_io_cache_percent_avg,
       SUM(CASE WHEN read_io_cache_percent < 50 THEN 1 ELSE 0 END) AS low_io_cache_count,
       SUM(waiting_for_compute_duration_ms) AS waiting_for_compute_ms_sum,
       SUM(compilation_duration_ms)         AS compilation_duration_ms_sum
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL 30 DAYS
  AND start_time < current_date()
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id
