---
phase: 02-table-export-via-pins
plan: 03
subsystem: data-validation
tags: [pins, s3, r, python, arrow, parquet, validation]
dependency-graph:
  requires: [02-02]
  provides: [cross-language-pin-validation, phase-2-acceptance-tests]
  affects: [03-ducklake-catalogue, 04-spatial-tables]
tech-stack:
  added: []
  patterns: [arrow-fallback-for-multi-file-pins, memory-safe-large-table-validation]
key-files:
  created:
    - scripts/validate_pins_r.R
    - scripts/validate_pins.py
  modified: []
decisions:
  - id: multi-file-arrow-fallback
    choice: "Python pin_read fails on multi-file pins; arrow dataset fallback reads them correctly"
    reason: "pins Python library does not support reading multi-file pin_upload pins via pin_read"
metrics:
  duration: ~5 min
  completed: 2026-02-22
---

# Phase 02 Plan 03: Cross-Language Pin Validation Summary

**One-liner:** R and Python validation scripts confirm all 10 non-spatial pins are discoverable, readable, and have correct metadata from both languages.

## What Was Done

### Task 1: R validation script (7c013fe)

Created `scripts/validate_pins_r.R` that validates all pins on the S3 board:

- Lists all pins via `pin_list(board)` -- found 10
- For each pin: reads metadata (`pin_meta`), checks title and column descriptions
- Standard pins read via `pin_read`; large/multi-file pins read via arrow (`open_dataset` / `read_parquet`) to avoid OOM
- All 10/10 pins pass with correct row counts, column counts, and metadata

### Task 2: Python validation script (7620d3b)

Created `scripts/validate_pins.py` that validates all pins from Python:

- Lists all pins via `board.pin_list()` -- found 10
- For each pin: reads metadata (`pin_meta`), checks title and column descriptions
- Standard pins read via `board.pin_read()`; multi-file pins (from `pin_upload`) fall back to pyarrow dataset reading via S3
- All 10/10 pins pass with correct row counts, column counts, and metadata

## Verification Results

| Check | Result |
|-------|--------|
| R script exits 0, all pins PASS | Yes -- 10/10 |
| Python script exits 0, all pins PASS | Yes -- 10/10 |
| Pin count matches R and Python | Yes -- both report 10 pins |
| Metadata (title, columns) accessible both languages | Yes |
| Large EPC table (19.3M rows, 7 files) handled gracefully | Yes -- arrow fallback in both languages |

## Pin Validation Detail

| Pin Name | Rows | Cols | R | Python |
|----------|------|------|---|--------|
| boundary_lookup_tbl | 2,720,556 | 14 | PASS | PASS |
| ca_la_lookup_tbl | 106 | 5 | PASS | PASS |
| eng_lsoa_imd_tbl | 33,755 | 25 | PASS | PASS |
| iod2025_tbl | 33,755 | 56 | PASS | PASS |
| la_ghg_emissions_tbl | 559,215 | 15 | PASS | PASS |
| la_ghg_emissions_wide_tbl | 7,657 | 50 | PASS | PASS |
| postcode_centroids_tbl | 2,717,743 | 60 | PASS | PASS |
| raw_domestic_epc_certificates_tbl | 19,322,638 | 93 | PASS | PASS |
| raw_non_domestic_epc_certificates_tbl | 727,188 | 41 | PASS | PASS |
| uk_lsoa_tenure_tbl | 285,376 | 5 | PASS | PASS |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Fixed R script collect() without dplyr**

- **Found during:** Task 1 verification
- **Issue:** `head(ds, 5) |> collect()` requires dplyr, which was not loaded. The EPC multi-file pin failed with "could not find function collect".
- **Fix:** Replaced `collect()` calls with `as.data.frame()` which works natively with arrow.
- **Files modified:** `scripts/validate_pins_r.R`
- **Commit:** 7c013fe

**2. [Rule 1 - Bug] Fixed Python pin_read failure on multi-file pins**

- **Found during:** Task 2 verification
- **Issue:** Python `pins` library `pin_read()` cannot handle multi-file pins created via `pin_upload()`. It constructs an invalid S3 path by string-joining the file list.
- **Fix:** Added arrow dataset fallback -- when `pin_read` raises an exception (not MemoryError), reads parquet files directly via `pyarrow.dataset` and `s3fs.S3FileSystem`.
- **Files modified:** `scripts/validate_pins.py`
- **Commit:** 7620d3b

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Multi-file pin reading in Python | Arrow dataset fallback when pin_read fails | Python pins library does not support multi-file pin_upload pins via pin_read; arrow reads them correctly |
| Large table validation strategy | Arrow-only (no full pandas load) for >5M rows | Prevents OOM on the 19.3M-row EPC table |

## Known Issues

- **s3fs version warning** (cosmetic): Python outputs a deprecation warning about s3fs version. No functional impact.
- **Python pin_read limitation**: Multi-file pins from `pin_upload` cannot be read via `board.pin_read()` in Python. Analysts working with the EPC table in Python should use pyarrow or DuckDB directly.

## Next Phase Readiness

Phase 2 is now complete. All 10 non-spatial tables are:
- Exported as versioned pins to S3 (02-02)
- Validated as readable from R with correct metadata (02-03)
- Validated as readable from Python with correct metadata (02-03)

Ready for Phase 3 (DuckLake Catalogue) and Phase 4 (Spatial Tables).
