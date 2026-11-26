# `aer-rdp` E2E Test Suite (`e2e/`)

Opaque-box, requirement-driven 4-tier E2E test suite for `aer-rdp` covering all **11 Feature Areas (`FA01`–`FA11`)** and **135 test cases** (`57` Tier 1 + `57` Tier 2 + `14` Tier 3 + `7` Tier 4), plus **8 binary-independent self-tests** (`e2e/tests_self/`).

## Quick Commands

```bash
# 1. Dry-run discovery, thresholds, and execution plan (no binaries required)
bash e2e/run_e2e.sh --dry-run

# 2. Self-tests (SELF-01..SELF-08: manifest, thresholds, schemas, runner CLI, mock plumbing, contracts)
bash e2e/run_e2e.sh --self-test

# 3. Run sequential Tiers 1 -> 2 -> 3 -> 4 against compiled binaries (M5 Phase 1)
bash e2e/run_e2e.sh --tier all --channel all --stop-on-tier-failure --report artifacts/e2e/report.json
```

## Notes
- Uses Python 3.12 stdlib `unittest` exclusively (zero third-party `pip` dependencies), while maintaining `pytest`-discoverable `Test*`/`test_*` naming.
- Runtime reports default to `artifacts/e2e/` (preserved across `scripts/sync-to-builder.ps1` syncs).
