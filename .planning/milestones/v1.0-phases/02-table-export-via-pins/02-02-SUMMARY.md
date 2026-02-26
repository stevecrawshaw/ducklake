---
phase: 02-table-export-via-pins
plan: 02
subsystem: data-export
tags: [pins, s3, parquet, bulk-export, pin-upload, chunking, duckdb, arrow]

# Dependency graph
requires:
  - phase: 02-01
    provides: table metadata extraction, spatial table identification, cross-language interop validation
provides:
  - All 10 non-spatial tables available as pins on S3 under pins/ prefix
  - Custom metadata (table description, column descriptions, column types) on every pin
  - Validated large-table chunked strategy for tables with >2GB parquet output
affects: [02-03, phase-5]

# Tech tracking
tech-stack:
  added: none (uses existing pins, duckdb, arrow, DBI)
  patterns:
    - chunked-pin-upload for tables exceeding curl 2GB upload limit
    - tryCatch per-table error handling with failure accumulation
    - DuckDB COPY TO tempdir for memory-safe large-table parquet export

key-files:
  created:
    - scripts/export_pins.R
  modified: []

key-decisions:
  - "Chunked pin_upload for large tables: split into 7 x 3M-row parquet files to work around curl's 2GB single-file upload limit"
  - "Used ROW_GROUP_SIZE 100000 in DuckDB COPY TO for memory-efficient streaming"
  - "pin_write used for all 9 standard tables; pin_upload with chunking used only for raw_domestic_epc_certificates_tbl"

patterns-established:
  - "Chunked pin_upload pattern: COPY TO parquet shards in tempdir, then pin_upload(paths = dir_ls(temp_dir, glob = '*.parquet'))"
  - "Per-table tryCatch with failure accumulation: continue on error, report all failures at the end"
  - "Custom metadata structure: list(source_db, columns = named list of descriptions, column_types = named list of types)"

# Metrics
duration: ~21min
completed: 2026-02-22
---

# Phase 2 Plan 02: Bulk Pin Export Summary

**Bulk export of 10 non-spatial tables (26.4M rows) as pins to S3 with metadata, using chunked pin_upload for the 19M-row EPC table to work around curl's 2GB upload limit**

## Performance

- **Duration:** ~21 min
- **Started:** 2026-02-22
- **Completed:** 2026-02-22
- **Tasks:** 1 (+ checkpoint approved by user)
- **Files modified:** 1

## Accomplishments

- All 10 non-spatial tables exported successfully as versioned pins to S3 (10/10, 0 failures)
- Total rows exported: 26,407,989 across all tables
- Large-table strategy validated: raw_domestic_epc_certificates_tbl (19.3M rows) exported as 7 x 3M-row parquet shards via chunked pin_upload
- Custom metadata round-tripped correctly for all pins (table description, column descriptions, column types)
- pin_list(board) confirms all expected table names are visible on S3

## Task Commits

Each task was committed atomically:

1. **Task 1: Bulk pin export script with large-table handling** - `6e95111` (feat)

**Plan metadata:** (this commit)

## Files Created/Modified

- `scripts/export_pins.R` - Bulk export script: connects to source DuckDB, identifies non-spatial tables, exports all using pin_write (standard) or chunked pin_upload (large), with tryCatch per-table error handling and full summary reporting

## Decisions Made

- **Chunked pin_upload for EPC table:** Single-file pin_upload failed at the curl layer due to the 2GB upload limit. Fixed by splitting the parquet output into 7 x 3M-row files using DuckDB `COPY TO` with `PARTITION BY rowgroup` and uploading all shards via `pin_upload(paths = dir_ls(...))`. This is now the established pattern for any table with >2GB parquet output.
- **Standard vs large-table threshold:** LARGE_TABLE_THRESHOLD = 5,000,000 rows. Tables below use pin_write (simpler, single file); tables above use DuckDB COPY TO + chunked pin_upload.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Single-file pin_upload failed due to curl 2GB upload limit**

- **Found during:** Task 1 (Bulk pin export script with large-table handling)
- **Issue:** The original plan used `pin_upload()` with a single large parquet file written via DuckDB `COPY TO`. For raw_domestic_epc_certificates_tbl (19.3M rows), the resulting parquet file exceeded curl's 2GB single-file upload limit, causing the upload to fail.
- **Fix:** Changed the large-table strategy to chunk the output into 7 x 3M-row parquet files (using DuckDB `COPY TO` with row-group partitioning into a temp directory), then call `pin_upload(board, paths = dir_ls(temp_dir, glob = "*.parquet"), ...)` with all shard paths. pins treats the collection as a single multi-file pin.
- **Files modified:** scripts/export_pins.R
- **Verification:** EPC table exported successfully; pin_list confirms it is visible; spot-check of pin_meta shows correct metadata.
- **Committed in:** 6e95111 (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** Auto-fix necessary for correct operation. No scope creep. The chunked strategy is now the established pattern for large tables.

## Issues Encountered

None beyond the curl upload limit bug (documented as deviation above). All 10 tables exported cleanly, 0 failures.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All 10 non-spatial tables are available as pins on S3 with metadata
- 02-03 cross-language validation (R and Python read all pins) can proceed immediately
- Chunked pin_upload pattern is established and ready for spatial tables in Phase 4 if needed
- No blockers

---
*Phase: 02-table-export-via-pins*
*Completed: 2026-02-22*
