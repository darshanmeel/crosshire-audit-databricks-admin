## What & why

<!-- One or two sentences: what this changes and the reason. -->

## Checklist

- [ ] `python tools/lint_headers.py` passes (headers + manifest + `.sqlfluff` in sync)
- [ ] If I changed a query header, I regenerated: `python tools/build_manifest.py` and `python tools/build_sqlfluff_params.py`
- [ ] Query files stay plain `SELECT` (no writes — the only write path is `run_audit.py --write-to`)
- [ ] New/changed `:params` are declared in the `-- params:` header (the linter enforces this)
- [ ] Any `status` column emits only `OK` / `WARN` / `CRITICAL` / `NOT_ASSESSED`
