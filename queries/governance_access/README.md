# Governance, Access & Security

> 📖 **Guided HTML tour:** [`docs/index.html`](../../docs/index.html) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. From this domain: [`access_runas_escalation`](../../docs/index.html#q-access_runas_escalation). *(Phase 1 = top 10; more in phases.)*

This domain answers "who can touch what, who did touch what, and where is sensitive data leaking out of its guardrails." The queries read Unity Catalog's audit log, data/table/column lineage, network-policy denials, the privilege/tag/mask/row-filter metadata in `information_schema`, and auto-detected data classification — to inventory the current access posture and surface hygiene gaps (dead tables, untagged PII propagation, classified-but-unmasked columns, run-as escalation, login concentration, network exfiltration attempts).

Almost everything here lives in Unity Catalog system schemas, so the hard dependency is UC + a metastore with system-table sharing enabled, and the collecting principal must have `SELECT` on `system.*`. Because `information_schema` is privilege-aware and most of these tables are Preview and/or feature-gated, an empty or `TABLE_OR_VIEW_NOT_FOUND` result is expected and is not the same as "clean."

## System tables used

### system.access.audit
- **What it is:** The Unity Catalog / account audit log — every recorded control-plane and data-access action (logins, permission changes, run-as, vector-search queries, etc.).
- **Grain:** One row per audited event (a single action by a single actor at a point in time).
- **Key columns used:** `service_name` (e.g. `accounts`, `accountsAccessControl`, `unityCatalog`, `vectorSearch`), `action_name` (the operation; note action values are representative, not an exhaustive enum — group by it, never hardcode a filter list), `user_identity` struct → `email` / `subject_name` (the acting principal; `subject_name`, NOT `subjectName`; frequently NULL), `source_ip_address`, `response.status_code` (200 = success), `identity_metadata.run_by` / `identity_metadata.run_as` (for run-as escalation; usually NULL for ordinary single-user actions), `request_params['endpoint_name']` (vector-search endpoint), `event_time`, `event_date` (partition column used for windowing).
- **Availability:** Preview. Requires UC + system-table sharing enabled on the metastore, and `SELECT` on `system.access`. Account-level events are global (`workspace_id=0`); workspace events are regional. ~15-minute ingest lag — treat the most recent hour as provisional.

### system.access.column_lineage
- **What it is:** Column-to-column data-flow lineage captured when UC observes an operation.
- **Grain:** One row per observed column-level lineage edge (source column → target column) per event.
- **Key columns used:** `source_table_full_name` / `target_table_full_name`, discrete `source_table_catalog/schema/name` + `source_column_name` (and target equivalents), `entity_type`, `direct_access` (true = direct read/write; false = indirect/view-expansion), `created_by`, `event_time`, `event_date`.
- **Availability:** GA. Requires UC + `SELECT` on `system.access`. Regional. **Subset by design** — operations with no source (e.g. `INSERT ... VALUES` literals) emit no row, so it undercounts; report as coverage-bounded, never a proof of absence.

### system.access.table_lineage
- **What it is:** Table-level data-flow lineage (read / write / read-write relationships between tables and other entities).
- **Grain:** One row per observed table-level lineage edge per event.
- **Key columns used:** `source_table_full_name` / `target_table_full_name` (source NULL on write-only events, target NULL on read-only), discrete `source_table_catalog/schema/name`, `source_type` / `target_type`, `entity_type`, `direct_access`, `created_by`, `event_time`, `event_date`.
- **Availability:** GA, rolling **365-day** retention (but retention on `system.access.*` is workspace-configurable). UC + `SELECT` on `system.access`. Regional. Empty lineage means "not captured" (MERGE/JDBC/path/temp-view gaps), NOT "unused."

### system.access.inbound_network
- **What it is:** Inbound (ingress) network-policy enforcement events.
- **Grain:** One row per inbound network event (this query keeps DENY / DENY_DRY_RUN only).
- **Key columns used:** `policy_outcome` (DENY / DENY_DRY_RUN), `rule_label`, `request_path`, `authenticated_as` (principal), `source.ip` nested subfield (source IP — exact subfield name unverified), `event_time` (this table has **no `event_date` column**).
- **Availability:** Preview. Regional. Requires a configured ingress network policy — empty if none. Retention **30 days** (look-back capped at 30d regardless of requested window).

### system.access.outbound_network
- **What it is:** Outbound (egress) network-policy enforcement events — the exfiltration-control audit surface.
- **Grain:** One row per outbound network event (this query keeps denials only).
- **Key columns used:** `network_source_type`, `destination_type`, `access_type`, `destination`, `dns_event.rcode` (NULL unless `destination_type=DNS`), `storage_event.rejection_reason` (NULL unless `destination_type=STORAGE`), `event_time` (**no `event_date` column**).
- **Availability:** Preview. Regional. Requires a configured egress policy — empty means "not assessed / no egress policy," NOT "zero exfiltration." Denials only — no allowed-traffic baseline, so no allow/deny ratio. Retention **365 days**.

### system.data_classification.results
- **What it is:** Auto-detected data classification (PII/sensitivity scan results) for enabled catalogs.
- **Grain:** One row per detected classification per column (this query aggregates to one row per catalog/schema/table/column/class_tag/data_type).
- **Key columns used:** `catalog_name`, `schema_name`, `table_name`, `column_name`, `class_tag` (the detected sensitivity class), `confidence` (HIGH / LOW), `data_type`, `frequency` (float 0–1, share of sampled values matching), `first_detected_time` / `latest_detected_time`. The `samples array<string>` column is deliberately **dropped** (it holds raw sample values = live sensitive data).
- **Availability:** Preview, 13-month retention, regional. Requires **both** the data-classification feature **and** the `system.data_classification` schema enabled — this is a *separate* schema from `system.access`, so enabling one does not enable the other. Covers **enabled catalogs only**; unclassified columns are simply absent. If disabled, treat as "feature not enabled," not empty.

### system.information_schema.column_masks
- **What it is:** Current-state inventory of column masks applied in the metastore.
- **Grain:** One row per masked column.
- **Key columns used:** `table_catalog`, `table_schema`, `table_name`, `column_name`, `mask_name`, `using_columns` (columns the mask function reads).
- **Availability:** Public Preview, DBR 12.2 LTS+. Metastore-wide but **privilege-aware / object-visibility-scoped** — tables the collector can only BROWSE are excluded, so a missing mask row can mean "not visible to the collector," which would *overstate* unmasked coverage. Label completeness rather than asserting a clean count.

### system.information_schema.row_filters
- **What it is:** Current-state inventory of row filters applied in the metastore.
- **Grain:** One row per filtered table.
- **Key columns used:** `table_catalog`, `table_schema`, `table_name`, `filter_name`, `target_columns` (columns the filter reads).
- **Availability:** Public Preview, DBR 12.2 LTS+. Metastore-wide, privilege-aware / object-visibility-scoped.

### system.information_schema.column_tags
- **What it is:** Manual governance tags applied at the column level.
- **Grain:** One row per (column, tag) pair.
- **Key columns used:** `catalog_name` / `schema_name` / `table_name` / `column_name` (discrete identifiers — join with `=`, never `LIKE CONCAT(...)` since `_` is a LIKE wildcard), `tag_name`, `tag_value`. Tag names/values are free-text and case-sensitive.
- **Availability:** UC. Privilege-aware → the tag inventory is privilege-scoped. Distinct from auto-detected classification in `data_classification.results`.

### system.information_schema.table_tags
- **What it is:** Manual governance tags applied at the table level.
- **Grain:** One row per (table, tag) pair.
- **Key columns used:** `TAG_NAME`, `TAG_VALUE` (plus the object identifier columns).
- **Availability:** UC, privilege-aware. (Sibling `CATALOG_TAGS` / `SCHEMA_TAGS` / `VOLUME_TAGS` exist but are intentionally excluded here as unverified.)

### system.information_schema.table_privileges
- **What it is:** Table-level grant state.
- **Grain:** One row per grant (grantee × privilege × table).
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE`, `TABLE_CATALOG` / `TABLE_SCHEMA` / `TABLE_NAME`. (`IS_GRANTABLE` is always `'NO'` / reserved — not collected.)
- **Availability:** UC. **Privilege-aware** — a principal sees only its own grants on objects it can see; even a high-privilege audit SP cannot fully reproduce `SHOW GRANTS`. Always label results "partial — privilege-aware."

### system.information_schema.catalog_privileges
- **What it is:** Catalog-level grant state.
- **Grain:** One row per grant (grantee × privilege × catalog).
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE`, `CATALOG_NAME`.
- **Availability:** UC, privilege-aware (same caveat as `table_privileges`).

### system.information_schema.schema_privileges
- **What it is:** Schema-level grant state.
- **Grain:** One row per grant (grantee × privilege × schema).
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE` (the only columns read; per-view object-name columns are inferred/unverified).
- **Availability:** UC, privilege-aware.

### system.information_schema.connection_privileges
- **What it is:** Grant state on UC connections (e.g. Lakehouse Federation / external system connections).
- **Grain:** One row per grant on a connection.
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE`.
- **Availability:** UC, privilege-aware; empty if no connections defined.

### system.information_schema.credential_privileges
- **What it is:** Grant state on UC credentials.
- **Grain:** One row per grant on a credential.
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE`.
- **Availability:** UC, privilege-aware. (`STORAGE_CREDENTIAL_PRIVILEGES` is deprecated and excluded.)

### system.information_schema.external_location_privileges
- **What it is:** Grant state on UC external locations.
- **Grain:** One row per grant on an external location.
- **Key columns used:** `GRANTEE`, `PRIVILEGE_TYPE`.
- **Availability:** UC, privilege-aware; empty if no external locations defined.

### system.information_schema.tables
- **What it is:** Metastore table catalog (object inventory).
- **Grain:** One row per table/view.
- **Key columns used:** `table_catalog`, `table_schema`, `table_name`, `table_type` (filtered to `MANAGED` / `EXTERNAL`), `table_owner`, `created`, `last_altered` (can be NULL / late-populated → "age unknown").
- **Availability:** UC. **Privilege-aware** — tables the collector cannot see are absent (not "dead"). Used as the object universe for dead-table detection.

## Queries

### Access & audit history
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `access_admin_role_change_events` | 90-day rollup of grant/admin change events (by service, action, actor) with counts, distinct source IPs, first/last event time | Admin & role-change hygiene — who altered permissions, from where, how often; pairs with the current-state grant inventory |
| `access_login_concentration` | 30-day login rollup per principal × source IP × action, with success vs non-success counts | Spot login concentration, credential-stuffing / anomalous-IP patterns, and MFA/credential event distribution |
| `access_runas_escalation` | 30-day events where `run_by <> run_as` (someone executed as a different identity) | Detect run-as / privilege-escalation activity; sparse by design, so empty ≠ "no escalation" |

### Grants & privilege inventory (current state)
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `access_grants_inventory` | Grant counts and distinct objects by object scope (TABLE, CATALOG) × privilege × grantee | Baseline privilege map — who holds what, at what breadth; input to least-privilege review |
| `access_grants_inventory_extended` | Grant counts by scope (SCHEMA, CONNECTION, CREDENTIAL, EXTERNAL_LOCATION) × privilege × grantee | Extends the grant map to schemas and integration objects (connections/credentials/external locations) — common blind spots |

### Data classification, tags, masks & row filters
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `access_data_classification_inventory` | Auto-detected classification per column (class tag, confidence, max frequency, first/last detected) | Know where PII/sensitive data actually lives, per the scanner |
| `access_tags_inventory` | Manual governance tag inventory at column and table scope (tag name/value × count) | Measure tagging discipline; the manual-tag counterpart to auto-classification |
| `access_column_masks_inventory` | One row per masked column (mask name + using columns) | Verify which sensitive columns are actually masked |
| `access_row_filters_inventory` | One row per row-filtered table (filter name + target columns) | Verify row-level access controls are in place |
| `access_classified_unmasked` | HIGH-confidence classified columns LEFT JOINed to masks, flagging `is_unmasked` | The headline gap: sensitive data the scanner found that has no mask applied |
| `access_pii_propagation_untagged` | Direct lineage flows from sensitivity-tagged source columns into UNTAGGED target columns, with responsible `created_by` | Catch PII leaking into new columns that lost their governance tag — with the principal to follow up with |

### Lineage, blast radius & cleanup
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `access_table_lineage_blast_radius` | 90-day table-level lineage edges classified READ / WRITE / READ_WRITE, with event counts and distinct principals | Understand downstream blast radius before changing/dropping a table |
| `access_column_lineage_sensitive_reach` | 90-day column-level lineage edges (source→target column) with event counts and distinct principals | Trace exactly how far a sensitive column propagates; feeds the classified-but-unmasked reach analysis |
| `access_dead_table_candidates` | MANAGED/EXTERNAL tables that never appeared as a lineage source in the window, with owner and age | Cleanup **candidate** list (cross-check required) — never a DROP recommendation on its own |

### Network & endpoint security
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `access_network_inbound_denials` | 30-day inbound (ingress) policy denials by outcome, rule, request path, principal, source IP | Surface blocked ingress attempts and validate ingress-policy coverage |
| `access_network_outbound_denials` | 30-day outbound (egress) policy denials by source/destination type, access type, destination, with DNS/storage detail | Exfiltration monitoring — what egress was blocked and why |
| `access_vector_search_traffic` | Vector Search query/scan traffic per endpoint per day | Identify provisioned-but-unqueried (idle) Vector Search endpoints; joined to spend for retire-candidate detection |

## Notes

- **Date windows are per-query, not uniform:** 30 days (`access_login_concentration`, `access_runas_escalation`, `access_network_*`), 90 days (`access_admin_role_change_events`, `access_table_lineage_blast_radius`, `access_column_lineage_sensitive_reach`), and a `:period_days` parameter (`access_dead_table_candidates`, `access_pii_propagation_untagged`, `access_vector_search_traffic`). Inbound network is hard-capped at 30-day retention regardless of the requested window. Widen windows only as far as your workspace-configured `system.access.*` retention allows — a short window over-flags quarterly/long-tail tables as "dead."
- **`event_date` vs `event_time`:** `audit`, `table_lineage`, and `column_lineage` have a partition-friendly `event_date` column; the network tables (`inbound_network`, `outbound_network`) do **not** — they filter on `event_time` against `current_timestamp()`.
- **Principal masking:** Every query masks identity fields (email → `xx****@****`, other names → `xx****`, UUIDs and `__REDACTED__` left intact) so the output is safe to share. Vector-search endpoint names are similarly truncated.
- **Privilege-aware = "partial", always:** `information_schema` privilege/mask/row-filter/tag/table views only show what the running principal can see. Run collection under a high-privilege audit service principal, and still label results as partial — you cannot reproduce a full `SHOW GRANTS` graph, and a missing mask/tag/table row can mean "not visible," not "not there."
- **Empty ≠ clean, and errors are expected:** Preview / feature-gated tables (data classification, network policies, masks, row filters) return nothing when the feature isn't enabled or used, and `TABLE_OR_VIEW_NOT_FOUND` when the schema isn't provisioned. Both are valid outcomes — degrade to "not assessed / feature not enabled," never to a false all-clear.
- **Lineage is a subset:** table/column lineage misses operations UC doesn't observe (MERGE/JDBC/path/temp-view/`INSERT ... VALUES`). Dead-table and propagation findings are coverage-bounded candidates to cross-check against `system.access.audit`, `query.history`, and `system.storage.table_metrics_history` — not proof.
- **A few subfield names are unverified** (`inbound_network.source.ip`; the sibling privilege views' object-name columns in `access_grants_inventory_extended`; PII `tag_name`/`tag_value` conventions in `access_pii_propagation_untagged`). The queries are written to use only confirmed columns or to degrade gracefully; confirm with `DESCRIBE` before relying on the unverified fields.
