-- query_id: query_cache_coldstart
-- title: Result-cache hit rate and IO-cache cold-start latency
-- domain: performance   tier: standard
-- reads: system.query.history
-- requires: SELECT on system.query; GA (system.query.history is generally available)
-- params: :period_days (default 30) rolling window in days; :warn_io_cache_pct (default 50) average read_io_cache_percent below which a day+warehouse flags WARN, and the per-query low-cache threshold; :crit_io_cache_pct (default 20) average read_io_cache_percent below which it flags CRITICAL
-- confidence: confirmed
-- confidence_note: Columns verified against system.query.history in a live workspace.
-- read_this: One row = a day + warehouse whose queries were checked for cache reuse. The columns that matter are read_io_cache_percent_avg (average share of scanned bytes served from disk/IO cache) and waiting_for_compute_ms_sum (cumulative cold-start/provisioning wait). A day with a low average and a high low_io_cache_count is spending compute re-reading data it should be caching.
-- healthy: read_io_cache_percent_avg at/above :warn_io_cache_pct (field heuristic - tune :warn_io_cache_pct for your account).
-- investigate_if: read_io_cache_percent_avg below :warn_io_cache_pct (WARN) or below :crit_io_cache_pct (CRITICAL) - field heuristic.
-- actions: 1) re-run a representative query back-to-back to confirm it is actually cold rather than just infrequently reused (free); 2) pin hot tables to a warehouse that stays warm between runs, or extend the warehouse's auto-stop timeout to avoid cold starts between queries (config); 3) move latency-sensitive workloads to a warehouse that never idles down, such as a dedicated always-on warehouse (spend).
-- next: query_queuing_waits (if waiting_for_compute_ms_sum is also high), query_local_spillage (if the same warehouse also spills)
-- caveats: There are two distinct cache signals here and they are NOT one combined percentage: from_result_cache is a boolean (did this exact query hit the result cache) while read_io_cache_percent is the share of scanned bytes served from disk/IO cache - do not average or add them together. waiting_for_compute_duration_ms is cold-start latency from warehouse provisioning; compilation_duration_ms is metadata/optimizer-bound time - the two measure different things and should not be conflated. Whether Databricks reports NULL or 0 for read_io_cache_percent on a non-scan statement (e.g. DDL, metadata-only queries) is undocumented, so a NULL average for a group may mean "no scans ran," not "no cache activity" - read it as not measured, never as zero. This table is regional, so a workspace with warehouses in multiple regions needs one run per region to see the full picture.
SELECT date(start_time) AS day, workspace_id, compute.type AS compute_type, compute.warehouse_id AS warehouse_id,
       COUNT(*) AS query_count,
       SUM(CASE WHEN from_result_cache THEN 1 ELSE 0 END) AS result_cache_hit_count,
       AVG(read_io_cache_percent) AS read_io_cache_percent_avg,
       SUM(CASE WHEN read_io_cache_percent < :warn_io_cache_pct THEN 1 ELSE 0 END) AS low_io_cache_count,
       SUM(waiting_for_compute_duration_ms) AS waiting_for_compute_ms_sum,
       SUM(compilation_duration_ms)         AS compilation_duration_ms_sum,
       -- status: worst-first band on average IO-cache hit rate (field heuristic; :warn_io_cache_pct / :crit_io_cache_pct).
       CASE
         WHEN AVG(read_io_cache_percent) IS NULL THEN 'NOT_ASSESSED'
         WHEN AVG(read_io_cache_percent) < :crit_io_cache_pct THEN 'CRITICAL'
         WHEN AVG(read_io_cache_percent) < :warn_io_cache_pct THEN 'WARN'
         ELSE 'OK'
       END AS status
FROM system.query.history
WHERE start_time >= current_date() - INTERVAL :period_days DAYS
  AND start_time < current_date()
GROUP BY date(start_time), workspace_id, compute.type, compute.warehouse_id
ORDER BY read_io_cache_percent_avg ASC
