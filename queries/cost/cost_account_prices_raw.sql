-- query_id: cost_account_prices_raw
-- title: Raw account price history by SKU
-- domain: cost   tier: lite
-- reads: system.billing.list_prices
-- requires: SELECT on system.billing; GA (system.billing.list_prices is generally available)
-- params: none - this collects full price history with no date filter (price_end_time NULL marks the currently active row)
-- confidence: needs_confirmation
-- confidence_note: Whether pricing.default (list rate) or pricing.effective_list.default (effective/negotiated rate) should anchor a discount-realization comparison is not fixed for this workspace; this query collects pricing.default raw so you can decide which to use yourself.
-- read_this: One row = a SKU's price at a point in time. The columns that matter are pricing_default (the list rate, cast to STRING because pricing.default is a high-precision decimal) and price_end_time (NULL means this is the currently active price for that SKU/cloud/currency).
-- healthy: n/a - inventory
-- investigate_if: n/a - inventory
-- actions: n/a - inventory (reference/join input)
-- next: cost_actual_vs_list_by_sku (to compare this rate against list/effective pricing), pricing_list_prices_raw (for the full raw pricing struct including effective_list and promotional)
-- caveats: There is no separate system.billing.account_prices table in this environment - the negotiated/account price basis lives on system.billing.list_prices itself. On list_prices, pricing.default is the list rate and pricing.effective_list.default is the effective (negotiated) rate, both decimal(38,18). This is collected raw, one row per SKU price change, so you must pick the right [price_start_time, price_end_time) window per usage row yourself. price_end_time NULL means the currently-active price - treat NULL as active, never as expired or zero. pricing.default is a decimal so numeric arithmetic on it is safe. The join key for multi-cloud/multi-currency accounts is cloud + currency_code + sku_name, not sku_name alone.
SELECT price_start_time, price_end_time, account_id, sku_name, cloud, currency_code, usage_unit,
       CAST(pricing.default AS STRING) AS pricing_default
FROM system.billing.list_prices
ORDER BY sku_name, cloud, currency_code, price_start_time
