-- query_id: access_dead_table_candidates
-- source: system.access.table_lineage
-- feeds: dead-table / cleanup-candidate detection (gov-1); owner + age; cross-check inputs
-- confidence: needs_confirmation
-- caveats: A table that is NOT a lineage SOURCE in the window is a cleanup CANDIDATE, NOT proven unused — a SELECT with no downstream write emits NO lineage row at all, and write-only targets never appear as a source. So this is deliberately a candidate list to cross-check (against system.access.audit / query.history / system.storage.table_metrics_history), NEVER a DROP recommendation. Lineage is only captured when UC observes the operation; direct_access=false (indirect/view-expansion) edges are still counted as "appeared as a source" here so a view-mediated read does not falsely mark a base table dead. Retention on system.access.* is WORKSPACE-CONFIGURABLE; a short window over-flags quarterly/long-tail tables — widen :period_days where retention allows. We exclude system tables by CATALOG name ('system'), not a bare NOT LIKE 'system' (which has no wildcard and would behave as <> 'system' and miss system schemas). information_schema is privilege-aware: tables the collector service principal cannot see are absent, not "dead". last_altered/created can be NULL/late-populated on some object types — treated as "age unknown", never as a finding.
/* databricks_audit:access_dead_table_candidates */
WITH lineage_window AS (
  SELECT *
  FROM system.access.table_lineage
  WHERE event_date >= dateadd(day, -:period_days, current_date())
    AND event_date < current_date()
),
-- Every table that appeared as a lineage SOURCE in the window (any direct_access
-- value — an indirect/view-mediated read of a base table still proves it was read,
-- so we must NOT exclude direct_access=false here or we over-flag base tables).
-- Prefer the discrete *_catalog/_schema/_name columns over CONCAT vs _full_name,
-- because _full_name can be backtick-quoted for reserved-word identifiers.
source_tables AS (
  SELECT DISTINCT
         source_table_catalog AS catalog,
         source_table_schema  AS schema,
         source_table_name    AS name
  FROM lineage_window
  WHERE source_table_name IS NOT NULL
),
-- The managed/external tables this account holds (privilege-scoped inventory).
inventory AS (
  SELECT table_catalog,
         table_schema,
         table_name,
         table_type,
         table_owner,
         created,
         last_altered
  FROM system.information_schema.tables
  WHERE table_catalog <> 'system'
    AND table_schema <> 'information_schema'
    AND table_type IN ('MANAGED', 'EXTERNAL')
)
SELECT inv.table_catalog,
       inv.table_schema,
       inv.table_name,
       inv.table_type,
       CASE
         WHEN inv.table_owner IS NULL OR inv.table_owner = '__REDACTED__' THEN inv.table_owner
         WHEN inv.table_owner LIKE '%@%' THEN concat(substr(inv.table_owner, 1, 2), '****@****')
         WHEN inv.table_owner RLIKE '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN inv.table_owner
         ELSE concat(substr(inv.table_owner, 1, 2), '****')
       END AS table_owner,
       inv.created,
       inv.last_altered,
       -- Age in whole days since the object was last altered (NULL -> age unknown).
       datediff(current_date(), DATE(inv.last_altered)) AS days_since_altered
FROM inventory inv
LEFT JOIN source_tables src
  ON  inv.table_catalog = src.catalog
  AND inv.table_schema  = src.schema
  AND inv.table_name    = src.name
WHERE src.name IS NULL          -- never appeared as a lineage source in the window
