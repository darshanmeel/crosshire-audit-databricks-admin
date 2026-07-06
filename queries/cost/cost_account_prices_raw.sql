-- query_id: cost_account_prices_raw
-- source: system.billing.account_prices
-- feeds: actual-vs-list negotiated pricing (cost_actual_vs_list_by_sku); negotiated-discount realization %; per-SKU negotiated rate basis
-- confidence: needs_confirmation
-- caveats: account_prices carries the account's REAL negotiated rate but ONLY pricing.default (there is NO pricing.effective_list on this table — that lives on list_prices). Collected raw, one row per SKU price change, so the engine picks the right [price_start_time, price_end_time) window per usage row itself. price_end_time NULL = the currently-active negotiated price; downstream MUST treat NULL as active, never as "expired/zero". pricing.default is typed STRING in the docs — confirm numeric castability before arithmetic; the engine casts defensively and degrades to not_assessed if the cast yields no numeric rows. Join key for multi-cloud/multi-currency accounts is cloud + currency_code + sku_name, NOT sku_name alone.
-- NEEDS WORKSPACE CONFIRMATION: pricing.default on account_prices is documented as STRING; numeric CAST to DOUBLE is unverified. Until confirmed, the finding labels every derived dollar as negotiated-rate-unverified and never promotes it to usd_monthly.
/* databricks_audit:cost_account_prices_raw */
SELECT price_start_time, price_end_time, account_id, sku_name, cloud, currency_code, usage_unit,
       CAST(pricing.default AS STRING) AS pricing_default
FROM system.billing.account_prices
