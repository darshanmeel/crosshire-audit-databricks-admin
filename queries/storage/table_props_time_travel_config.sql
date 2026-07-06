-- query_id: table_props_time_travel_config
-- source: DESCRIBE EXTENDED <catalog>.<schema>.<table> (or SHOW TBLPROPERTIES) — NOT a system table
-- feeds: time-travel config (long retention = bloat risk); search optimization / data-skipping coverage
-- confidence: confirmed (all 7 property names + defaults verbatim)
-- caveats: Read per-table on a warehouse. Values are CalendarInterval strings (e.g. 'interval 30 days') — parse to days. Excessively large logRetentionDuration/deletedFileRetentionDuration is storage bloat from over-long time-travel retention. In DBR 18.0+, logRetentionDuration must be >= deletedFileRetentionDuration. delta.enableDeletionVectors default is workspace/runtime-dependent (no fixed default).
/* databricks_audit:table_props_time_travel_config */
-- Per-table; Delta properties are NOT in a system table. Engine runs DESCRIBE EXTENDED
-- (or SHOW TBLPROPERTIES) per managed Delta table and parses the property rows.
--   delta.logRetentionDuration            (default 'interval 30 days')
--   delta.deletedFileRetentionDuration    (default 'interval 1 week')
--   delta.dataSkippingNumIndexedCols      (default 32)
--   delta.dataSkippingStatsColumns        (default none)
--   delta.autoOptimize.optimizeWrite
--   delta.autoOptimize.autoCompact
--   delta.enableDeletionVectors
DESCRIBE EXTENDED main.sales.orders;
