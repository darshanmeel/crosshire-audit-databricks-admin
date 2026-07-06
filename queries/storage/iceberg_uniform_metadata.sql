-- query_id: iceberg_uniform_metadata
-- source: DESCRIBE EXTENDED <catalog>.<schema>.<table> (Delta UniForm / Iceberg section)
-- feeds: Iceberg / external metadata (UniForm / managed-Iceberg detection)
-- confidence: needs_confirmation — verifier status `unverifiable`
-- NEEDS WORKSPACE CONFIRMATION: the 'Delta Uniform Iceberg' section EXISTS per doc, but the exact output row/key strings to parse are UNVERIFIED. No specific key is emitted as fact. The customer's run on a UniForm-enabled table validates the section key strings.
-- caveats: Metadata only — no size, no metric table. Engine runs this on tables flagged EXTERNAL / non-DELTA by the inventory query and parses the UniForm/Iceberg section.
/* databricks_audit:iceberg_uniform_metadata */
-- NEEDS CONFIRMATION: the 'Delta Uniform Iceberg' section EXISTS per doc, but the exact
-- output row/key strings to parse are UNVERIFIED. Confirm on a UniForm-enabled table.
DESCRIBE EXTENDED main.sales.orders;
