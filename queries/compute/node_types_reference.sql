-- query_id:   node_types_reference
-- source:     system.compute.node_types
-- feeds:      oversized/right-sizing (vCPU/memory/GPU-per-node-type denominator)
-- confidence: confirmed
-- caveats:    Reference dimension, one row per node type; no aggregation. Join key node_type →
--             clusters.driver/worker_node_type and node_timeline.node_type. core_count double,
--             memory_mb long, gpu_count long. Indefinite retention.
/* databricks_audit:node_types_reference */
SELECT node_type, core_count, memory_mb, gpu_count, account_id
FROM system.compute.node_types
