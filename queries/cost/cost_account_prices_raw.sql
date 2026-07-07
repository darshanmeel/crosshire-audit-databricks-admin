-- query_id: cost_account_prices_raw
-- source: system.billing.list_prices
-- feeds: actual-vs-list negotiated pricing (cost_actual_vs_list_by_sku); negotiated-discount realization %; per-SKU list/effective rate basis
-- confidence: needs_confirmation
-- caveats: NOTE: there is NO separate system.billing.account_prices table in this environment; the account/negotiated price basis lives on system.billing.list_prices. On list_prices, pricing.default is the list rate and pricing.effective_list.default is the effective (negotiated) rate — both decimal(38,18). Collected raw, one row per SKU price change, so the engine picks the right [price_start_time, price_end_time) window per usage row itself. price_end_time NULL = the currently-active price; downstream MUST treat NULL as active, never as "expired/zero". pricing.default is decimal, so numeric arithmetic is safe. Join key for multi-cloud/multi-currency accounts is cloud + currency_code + sku_name, NOT sku_name alone.
-- NEEDS WORKSPACE CONFIRMATION: whether list-rate (pricing.default) or effective/negotiated rate (pricing.effective_list.default) should feed the negotiated-discount finding; this query collects pricing.default raw.
/* databricks_audit:cost_account_prices_raw */
SELECT price_start_time, price_end_time, account_id, sku_name, cloud, currency_code, usage_unit,
       CAST(pricing.default AS STRING) AS pricing_default
FROM system.billing.list_prices
