---
phase: 02-table-export-via-pins
plan: 01
subsystem: data-export
tags: [metadata, duckdb, pins, interop, parquet, s3]
dependency_graph:
  requires: [01-aws-infrastructure]
  provides: [table-metadata, interop-validation, python-pins-aws]
  affects: [02-02, 02-03]
tech_stack:
  added: [pyarrow]
  patterns: [pins-s3-board, parquet-pin-type, custom-metadata-roundtrip]
key_files:
  created:
    - scripts/extract_metadata.R
    - scripts/test_interop.R
    - scripts/test_interop.py
  modified:
    - pyproject.toml
    - uv.lock
decisions:
  - id: D-0201-01
    description: "Use ca_la_lookup_tbl (106 rows, 5 cols) as interop test table -- smallest non-spatial table"
  - id: D-0201-02
    description: "Added pyarrow as explicit dependency -- required for Python parquet reading via pandas"
  - id: D-0201-03
    description: "Spatial identification via column data_type matching BLOB/GEOMETRY/WKB patterns"
metrics:
  duration: ~6 minutes
  completed: 2026-02-22
---

# Phase 02 Plan 01: Metadata Extraction and Interop Validation Summary

**One-liner:** DuckDB metadata extraction identifying 10 non-spatial + 8 spatial tables, with validated R-to-Python pins interop using parquet format and custom metadata round-trip.

## What Was Done

### Task 1: Metadata Extraction and Spatial Table Identification
- Created `scripts/extract_metadata.R` that connects to source DuckDB and extracts full table/column metadata
- Identified 18 tables total: 10 non-spatial (for export), 8 spatial (deferred to Phase 4)
- Spatial detection based on column data types: WKB_BLOB and GEOMETRY
- Saves metadata to `data/table_metadata.rds` (gitignored, regenerable)
- Commit: `71ab1e6`

### Task 2: Cross-Language Interop Validation
- Updated `pyproject.toml`: `pins` to `pins[aws]`, added `pyarrow>=19.0.0`
- Created `scripts/test_interop.R`: writes smallest table (ca_la_lookup_tbl, 106 rows) as parquet pin to S3
- Created `scripts/test_interop.py`: reads the pin back, validates data and metadata
- Custom metadata (column descriptions, column types, source_db) survives R->Python round-trip
- Commit: `c6b0d6c`

## Table Inventory

### Non-Spatial Tables (To Export in 02-02)

| Table | Comment | Rows | Cols |
|-------|---------|------|------|
| boundary_lookup_tbl | Boundary lookup table | 2,720,556 | 14 |
| ca_la_lookup_tbl | Combined authority local authority boundaries | 106 | 5 |
| eng_lsoa_imd_tbl | Indices of multiple deprivation England LSOA | 33,755 | 25 |
| iod2025_tbl | Table containing 56 columns | 33,755 | 56 |
| la_ghg_emissions_tbl | LA greenhouse gas emissions (long format) | 559,215 | 15 |
| la_ghg_emissions_wide_tbl | LA greenhouse gas emissions (wide format) | 7,657 | 50 |
| postcode_centroids_tbl | Postcode centroids UK | 2,717,743 | 60 |
| raw_domestic_epc_certificates_tbl | Domestic EPC data | 19,322,638 | 93 |
| raw_non_domestic_epc_certificates_tbl | Table containing 41 columns | 727,188 | 41 |
| uk_lsoa_tenure_tbl | Table containing 5 columns | 285,376 | 5 |

### Spatial Tables (Deferred to Phase 4)

| Table | Spatial Column | Type | Rows |
|-------|---------------|------|------|
| bdline_ua_lep_diss_tbl | shape | WKB_BLOB | 1 |
| bdline_ua_lep_tbl | shape | WKB_BLOB | 4 |
| bdline_ua_weca_diss_tbl | shape | WKB_BLOB | 1 |
| bdline_ward_lep_tbl | shape | WKB_BLOB | 130 |
| ca_boundaries_bgc_tbl | geom | GEOMETRY | 15 |
| codepoint_open_lep_tbl | shape | WKB_BLOB | 31,299 |
| lsoa_2021_lep_tbl | shape | WKB_BLOB | 698 |
| open_uprn_lep_tbl | shape | WKB_BLOB | 687,143 |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added pyarrow dependency**
- **Found during:** Task 2 Python test execution
- **Issue:** `pandas.read_parquet()` requires pyarrow or fastparquet engine; neither was installed
- **Fix:** Added `pyarrow>=19.0.0` to pyproject.toml dependencies
- **Files modified:** pyproject.toml, uv.lock

**2. [Rule 1 - Bug] Fixed vapply type mismatch in R interop script**
- **Found during:** Task 2 R test execution
- **Issue:** DuckDB COUNT(*) returns double, not integer; `vapply(..., integer(1))` failed
- **Fix:** Changed to `vapply(..., numeric(1))`
- **Files modified:** scripts/test_interop.R

## Decisions Made

| ID | Decision | Rationale |
|----|----------|-----------|
| D-0201-01 | Use ca_la_lookup_tbl as interop test table | Smallest non-spatial table (106 rows, 5 cols) for fast validation |
| D-0201-02 | Add pyarrow as explicit dependency | Required for Python parquet reading; pins[aws] alone insufficient |
| D-0201-03 | Spatial detection via BLOB/GEOMETRY/WKB column types | Covers both WKB_BLOB (older format) and GEOMETRY (DuckDB spatial) |

## Verification Results

| Check | Result |
|-------|--------|
| extract_metadata.R runs and prints inventory | PASS |
| data/table_metadata.rds created | PASS |
| test_interop.R writes pin and prints PASSED | PASS |
| test_interop.py reads pin and prints PASSED | PASS |
| Metadata round-trip (column descriptions in Python) | PASS |

## Next Phase Readiness

Plan 02-02 (bulk export) can proceed. Key inputs:
- Table list and metadata available via `extract_metadata.R` / `data/table_metadata.rds`
- Interop pattern validated: parquet pins with custom metadata work across R and Python
- Note: `raw_domestic_epc_certificates_tbl` has 19.3M rows -- 02-02 must handle chunking or memory management
- Note: s3fs version warning is cosmetic but may want to pin version in future
