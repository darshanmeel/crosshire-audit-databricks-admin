# Model Serving & AI

What's running on Model Serving, how much traffic and token throughput each endpoint handles, which endpoints are dormant (paying but idle), and whether AI Gateway is seeing abuse.

📖 **Full interactive docs → [every query, explained](https://learn.crosshire.ch/learn/tech/databricks/audit#d-serving)** — why it matters, what it does, how to read every output column, a sample of the result, and the caveats.

| # | Query | What it does |
|--:|---|---|
| 01 | [`compute_ai_gateway_usage`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-compute_ai_gateway_usage) | A daily per-workspace, per-endpoint, per-requester breakdown of AI Gateway request volume, its success / rate-limited / error split, input/output token throughput, and p50/p95/max latency. |
| 02 | [`compute_serving_dormant_endpoints`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-compute_serving_dormant_endpoints) | Every served entity in its latest configuration, paired with its request traffic over the trailing window, so entities that received no requests surface as dormant (`total_requests = 0`, `last_request_date` NULL). Each row also carries the endpoint's `net_dbus` and a list-price dollar estimate (`est_usd_list`), so a dormant endpoint shows the provisioned spend it is wasting. |
| 03 | [`compute_serving_endpoint_usage`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-compute_serving_endpoint_usage) | A daily rollup of Model Serving traffic per endpoint and served entity, showing total, successful and errored requests plus input/output token totals, with endpoint and entity names joined from the serving configuration, plus the endpoint's daily `net_dbus` and a list-price dollar estimate (`est_usd_list`). |
| 04 | [`serving_endpoint_traffic_by_endpoint`](https://learn.crosshire.ch/learn/tech/databricks/audit#q-serving_endpoint_traffic_by_endpoint) | One row per Model Serving endpoint over the trailing window, giving total requests, the success/error split, input and output token totals, the date each endpoint was last hit, plus the endpoint's `net_dbus` and a list-price dollar estimate (`est_usd_list`) for the window. |

<sub>★ = first-audit pick. This is a one-line index — the full write-up (output columns, sample rows, caveats) lives in the [interactive docs](https://learn.crosshire.ch/learn/tech/databricks/audit). The `.sql` files in this folder are the source of truth.</sub>
