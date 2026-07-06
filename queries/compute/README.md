# Compute — Clusters, Warehouses, Nodes

> 📖 **Guided HTML tour:** [`docs/index.html`](../../docs/index.html) explains the library query-by-query — why it matters, what it does in plain terms, how to read every output column, sample output, and caveats. From this domain: [`compute_warehouse_idle_gaps`](../../docs/index.html#q-compute_warehouse_idle_gaps). *(Phase 1 = top 10; more in phases.)*

This domain answers "what compute exists, how it's configured, and how hard it's actually working." The queries snapshot the current configuration of classic clusters, SQL warehouses, and instance pools (right-sizing, auto-stop, access mode, tagging, spot mix), and measure real behavior over time from per-minute node utilization and warehouse/instance state-transition events (idle ratio, autoscale churn, idle tails, spot-vs-on-demand). None of these tables carry DBU or dollars — they are configuration and behavioral signals; dollarizing them requires a join to `system.billing.usage` / list prices, which lives in the billing domain.

## System tables used

### system.compute.clusters
The configuration history of **classic** compute — all-purpose, jobs, Lakeflow SDP/pipeline, and pipeline-maintenance clusters. Excludes SQL warehouses and serverless entirely.
- **Grain:** slowly-changing — one row per `cluster_id` per configuration change (`change_time`). Queries take the latest row per `cluster_id` (`ROW_NUMBER() … ORDER BY change_time DESC`) and keep only rows where `delete_time IS NULL`.
- **Key columns used:** `cluster_id`, `cluster_name`, `owned_by`, `driver_node_type` / `worker_node_type`, `worker_count` (NULL when autoscaling), `min_autoscale_workers` / `max_autoscale_workers` (NULL when fixed-size), `auto_termination_minutes` (idle auto-stop config), `enable_elastic_disk`, `cluster_source`, `dbr_version` (runtime/EOL sprawl), `data_security_mode` (access-mode posture: `USER_ISOLATION` / `SINGLE_USER` / `LEGACY_*` / `NONE` / null), `policy_id` (NULL = no compute-policy coverage), `driver_instance_pool_id` / `worker_instance_pool_id`, `tags` (chargeback), `init_scripts`, `aws_attributes` / `azure_attributes` / `gcp_attributes` (STRUCTs — only the host cloud's is populated; hold spot/on-demand mix), `create_time` / `delete_time` / `change_time`, `workspace_id`, `account_id`.
- **Availability:** GA. Requires Unity Catalog and `SELECT` on `system.compute` (enable the `compute` schema per-metastore). Regional — run per metastore region. **No `runtime_engine` / Photon column** (confirmed absent on all clouds). Cloud-attribute STRUCTs are selected whole; extracting a named subfield is unverified.

### system.compute.warehouses
Configuration history of **SQL warehouses**.
- **Grain:** slowly-changing — one row per `warehouse_id` per change; queries take the latest row and keep `delete_time IS NULL`.
- **Key columns used:** `warehouse_id`, `warehouse_name`, `workspace_id`, `account_id`, `warehouse_type` (CLASSIC/PRO/SERVERLESS), `warehouse_channel`, `warehouse_size` (XS … 4X_LARGE, plus `5X_LARGE` Beta on PRO/SERVERLESS), `min_clusters` / `max_clusters` (autoscaling range), `auto_stop_minutes` (idle suspend config), `tags` (map, chargeback), `change_time`, `delete_time`.
- **Availability:** GA. UC + `SELECT` on `system.compute`. Regional. Empty if the workspace runs no SQL warehouses.

### system.compute.warehouse_events
State-transition event log for SQL warehouses — the behavioral counterpart to `warehouses`.
- **Grain:** one row per warehouse state-change event (`event_time`).
- **Key columns used:** `warehouse_id`, `event_type`, `event_time`, `cluster_count` (clusters running at event time). Authoritative 6-value enum: `SCALED_UP`, `SCALED_DOWN`, `STOPPING`, `RUNNING`, `STARTING`, `STOPPED`. (`SCALING_UP` / `SCALING_DOWN` appear in one official sample but are undocumented — the queries ignore them.)
- **Availability:** GA. UC + `SELECT` on `system.compute`. Regional. Carries **no DBU/$** — a warehouse's idle tail and autoscale churn are behavioral only. Retention is limited; window queries assume events exist within `:period_days`.

### system.compute.node_timeline
Per-minute hardware-utilization telemetry for classic-compute nodes (driver and every worker).
- **Grain:** one row per **node-minute** — a single minute-slice for one node. A raw row count is minutes, not hours.
- **Key columns used:** `cluster_id`, `node_type`, `driver` (bool), `start_time` / `end_time`, `cpu_user_percent` / `cpu_system_percent` (busy = sum; idle threshold in `compute_idle_node_ratio` is sum < 5%), `cpu_wait_percent`, `mem_used_percent` (0-100, **includes background processes**), `network_sent_bytes` / `network_received_bytes`. (`disk_free_bytes_per_mount_point` is a map — not selected.)
- **Availability:** GA. UC + `SELECT` on `system.compute`. Regional. **Retention is 90 days only** — `:lookback_days` is capped at 90; a longer window silently truncates. **Classic compute only** — there are no rows for SQL warehouses or serverless. Nodes that ran **< 10 minutes may not appear** (short-job blind spot). No DBU/$.

### system.compute.node_types
Static reference dimension of node/instance types and their hardware specs — the denominator for right-sizing.
- **Grain:** one row per `node_type`. No history, no aggregation.
- **Key columns used:** `node_type` (join key to `clusters.driver/worker_node_type` and `node_timeline.node_type`), `core_count` (double), `memory_mb` (long), `gpu_count` (long), `account_id`.
- **Availability:** GA. UC + `SELECT` on `system.compute`. Indefinite retention. Cloud-specific catalog (the node types listed are those available in the account's cloud/region).

### system.compute.instance_pools (Public Preview)
Configuration history of instance pools (pre-warmed idle VMs shared by clusters).
- **Grain:** slowly-changing — latest row per `instance_pool_id`, keep `delete_time IS NULL`.
- **Key columns used:** `instance_pool_id`, `instance_pool_name`, `node_type`, `min_idle_instances` (bigint — the always-on idle floor that drives pool waste), `max_capacity` (bigint), `idle_instance_autotermination_minutes`, `enable_elastic_disk`, `preloaded_spark_version`, `preloaded_docker_images` (Docker/preload risk), `tags`, `aws/azure/gcp_attributes` + `disk_spec` (STRUCTs selected whole), `create_time` / `delete_time` / `change_time`, `workspace_id`, `account_id`.
- **Availability:** **Public Preview** — may be empty or disabled (expect an empty-but-valid result or `TABLE_OR_VIEW_NOT_FOUND` if the schema isn't enabled). UC + `SELECT` on `system.compute`. Regional. Idle-waste dollarization needs node cost from the billing domain, not here.

### system.compute.instance_events (Public Preview)
Cloud-VM lifecycle/state-transition events for classic-compute instances — the source for spot-vs-on-demand mix and true instance idle-vs-active time.
- **Grain:** one row per instance state-change/lifecycle event (`event_time`).
- **Key columns used:** `workspace_id`, `instance_id`, `node_type`, `availability_type` (`ON_DEMAND`/`SPOT` on AWS/Azure, `ON_DEMAND`/`PREEMPTIBLE` on GCP), `state` (`INSTANCE_LAUNCHING` / `INSTANCE_READY` = idle / `INSTANCE_PLACED` = in use / `INSTANCE_TERMINATED`), `event_type` (`INSTANCE_LAUNCHING` / `STATE_TRANSITION`), `cluster_id` (populated only when `state = INSTANCE_PLACED`), `event_time`.
- **Availability:** **Public Preview** — may be empty/disabled (degrade to "preview table not populated"). UC + `SELECT` on `system.compute`. Regional, cloud-specific enum values. The query is a count/summary aggregate; converting `READY` vs `PLACED` events into exact idle-vs-active minutes needs per-instance windowing that is not attempted here.

## Queries

### Configuration snapshots (current-state, SCD "latest row")
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `classic_clusters_config_current` | Latest config of every live classic cluster: node types, autoscale range, auto-termination, DBR version, `data_security_mode`, `policy_id`, pool linkage, tags, init scripts, cloud attributes. | The right-sizing / governance baseline — find oversized fixed clusters, missing auto-stop, EOL runtimes, clusters with no compute policy, and untagged compute. |
| `sql_warehouse_config_current` | Latest config of every live SQL warehouse: type/channel/size, `min`/`max_clusters`, `auto_stop_minutes`, tags. | Spot oversized or never-auto-stopping warehouses and untagged warehouses for chargeback. |
| `instance_pools_idle_capacity` | Latest config of every live instance pool: `min_idle_instances`, `max_capacity`, idle auto-termination, preloaded images, node type. | Idle-pool waste (`min_idle_instances` are always-on VMs) and pool right-sizing; Docker/preload risk. *(Preview table.)* |
| `node_types_reference` | Static vCPU / memory / GPU per node type. | The capacity denominator to join against clusters and node_timeline for right-sizing math. |

### Utilization & idle behavior (time-window telemetry)
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `node_timeline_utilization` | Per cluster/node-type/role: minute-row count, avg & peak CPU, avg & peak memory, CPU-wait, total network sent/received, over `:lookback_days` (≤90). | Evidence for right-sizing — chronically low CPU/mem = oversized; high CPU-wait = I/O-bound; network as a coarse egress proxy. |
| `compute_idle_node_ratio` | Per cluster: total vs idle minute-slices (idle = CPU < 5%), the idle **ratio**, plus avg/peak CPU & memory and observed span. | Ranks classic clusters by how much of their runtime was genuinely idle — the auto-stop / auto-termination candidate list. |
| `instance_events_idle_active` | Per workspace/node-type/availability/state/event-type: event counts, distinct instances, first/last event. | Spot-vs-on-demand cost mix and a first look at idle (`INSTANCE_READY`) vs active (`INSTANCE_PLACED`) instances. *(Preview table.)* |

### SQL-warehouse event analysis
| Query id | What it returns | Why an admin cares |
|---|---|---|
| `sql_warehouse_events_activity` | Per warehouse & event_type: event count, first/last event time, max/avg `cluster_count`. | Resume/suspend churn, idle warehouses (no recent RUNNING/STARTING), and autoscaling/queuing behavior at a glance. |
| `compute_warehouse_idle_gaps` | Per warehouse: seconds spent RUNNING (the auto-stop idle tail), STARTING (cold-start tax) and STOPPED, plus the worst single RUNNING gap, via `LEAD(event_time)` over all events. | Quantifies how long warehouses sit RUNNING-but-idle before stopping — tune `auto_stop_minutes` down. Trailing (last) gap is left NULL, never assumed. |
| `compute_warehouse_autoscale_churn` | Per warehouse: `SCALED_UP`/`SCALED_DOWN` counts, total scaling events, observed span in hours, max/avg `cluster_count`. | Detects warehouses thrashing clusters up and down (cold-start + spin-up waste); the churn *rate* is scaling-events ÷ observed span. |

## Notes
- **Date windows:** utilization/event queries are parameterized — `:lookback_days` (node_timeline) and `:period_days` (warehouse_events, instance_events). **`node_timeline` retention is 90 days**, so `:lookback_days` must be ≤ 90; a longer window silently truncates to "last 90 days." Config-snapshot queries take no window (latest-row-wins).
- **No dollars in this domain.** No compute table carries DBU or cost. Idle/oversized findings become dollars only after joining to `system.billing.usage` and list prices (billing domain). `node_timeline`, `warehouse_events`, and `instance_events` are behavioral/telemetry signals only.
- **Classic-only telemetry.** `node_timeline` and `instance_events` cover classic compute; there is **no node-level utilization for SQL warehouses or serverless**. SQL-warehouse behavior comes only from `warehouse_events`; serverless has no node visibility here at all.
- **Masking.** Identifier/PII columns are masked in-query: `cluster_name` / `warehouse_name` / `instance_pool_name` are truncated to 2 chars + `****`; `owned_by` is redacted by pattern (emails → `xx****@****`, UUID service principals left intact, `__REDACTED__` passed through).
- **SCD gotcha.** Config tables are change-logs, not current-state views. Every snapshot query must reduce to the latest `change_time` per id and filter `delete_time IS NULL`; skipping this returns stale/duplicate/deleted rows.
- **Event enum discipline.** Only the 6 documented `warehouse_events` types are trusted; `SCALING_UP`/`SCALING_DOWN` are ignored. Idle/gap math uses `LEAD` over **all** events (not one filtered type) so a RUNNING→STOPPED tail is measured correctly, and open trailing intervals stay NULL.
- **Preview / availability.** `instance_pools` and `instance_events` are **Public Preview** — an empty result or `TABLE_OR_VIEW_NOT_FOUND` is expected and not an error. All of `system.compute` requires Unity Catalog, the `compute` schema enabled on the metastore, and `SELECT` granted on `system.*`. Tables are **regional** — run per metastore region and union if needed. A feature the account doesn't use (no pools, no SQL warehouses, no spot instances) yields a valid-but-empty result.
- **Short-job blind spot.** Nodes/clusters that ran under ~10 minutes may never appear in `node_timeline`, so their absence means "too short to measure," not "idle."
