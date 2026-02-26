---
phase: 05-refresh-pipeline-and-data-catalogue
plan: 02
subsystem: catalogue
tags: [R, duckdb, ducklake, pins, s3, parquet, catalogue, metadata, spatial]

# Dependency graph
requires:
  - phase: 05-refresh-pipeline-and-data-catalogue
    plan: 01
    provides: Unified refresh pipeline (scripts/refresh.R) with 18-table loop, DuckDB CLI patterns, pin export
  - phase: 03-ducklake-catalogue
    provides: DuckLake catalogue with 18 tables, 403 column comments, 12 views
  - phase: 04-spatial-data-handling
    provides: Spatial geometry metadata (geometry types, CRS, bounding boxes)
provides:
  - datasets_catalogue table in DuckLake (30 rows: 18 tables + 12 views) with descriptions, row counts, spatial metadata
  - columns_catalogue table in DuckLake (411 rows across 18 base tables) with descriptions and example values
  - Both catalogues pinned to S3 as parquet files
  - Catalogue generation integrated at end of every refresh run
affects: [analyst-documentation]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "ST_Extent_Agg for aggregate bounding boxes (not ST_Extent which is per-geometry)"
    - "Source DB column metadata with DuckLake type adjustments (avoids CLI output parsing for large result sets)"
    - "Example value sampling via R DuckDB connection with LIMIT 1000 subquery for scan cost capping"
    - "Programmatic view descriptions from name patterns (_weca_vw -> WECA-filtered subset)"

key-files:
  created: []
  modified:
    - scripts/refresh.R

key-decisions:
  - "Used source DB column metadata (has comments) rather than DuckLake metadata (comments lost on DROP+CREATE)"
  - "ST_Extent_Agg for aggregate bounding boxes -- ST_Extent returns per-geometry extent, not whole-table aggregate"
  - "Example values sampled via R DuckDB connection (not CLI) to avoid Windows encoding issues with box-drawing characters"
  - "GEOMETRY and BLOB columns get NULL example values -- binary data not meaningful as text"
  - "View descriptions generated programmatically from name patterns rather than hardcoded for all 12"

patterns-established:
  - "Catalogue-as-tables pattern: CREATE OR REPLACE TABLE via temp CSV for structured R data.frame to DuckLake"
  - "Hybrid metadata approach: source DB for comments, DuckLake types adjusted programmatically"

requirements-completed: [CAT-01, CAT-02, CAT-03]

# Metrics
duration: 51min
completed: 2026-02-24
---

# Phase 5 Plan 2: Data Catalogue Summary

**Two queryable catalogue tables (datasets_catalogue with 30 datasets + columns_catalogue with 411 columns) auto-generated at end of every refresh, pinned to S3 as parquet**

## Performance

- **Duration:** 51 min
- **Started:** 2026-02-24T09:38:54Z
- **Completed:** 2026-02-24T10:30:23Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- datasets_catalogue: 30 rows (18 tables + 12 views) with name, description, type, row_count, last_updated, source_table
- Spatial entries include geometry_type, crs, and bounding box (bbox_xmin/ymin/xmax/ymax) for all 8 spatial tables
- columns_catalogue: 411 rows across 18 base tables with column_name, data_type, description, and 3 example values
- 398 of 411 columns have example values populated (GEOMETRY/BLOB excluded)
- 404 of 411 columns have descriptions from source DB comments
- Both catalogues loaded into DuckLake and pinned to S3 as parquet
- Full refresh runs end-to-end: 18/18 tables + both catalogues in ~707 seconds

## Task Commits

Each task was committed atomically:

1. **Task 1: Add datasets_catalogue generation to refresh.R** - `148dc64` (feat)
2. **Task 2: Add columns_catalogue generation to refresh.R** - `47c2ec2` (feat)

**Plan metadata:** (pending)

## Files Created/Modified
- `scripts/refresh.R` - Extended with Steps 5-6: datasets_catalogue and columns_catalogue generation, DuckLake loading, S3 pinning

## Decisions Made
- Used source DB column metadata (`duckdb_columns()` on source connection) because DuckLake loses comments on DROP+CREATE during refresh; 404 of 411 columns have descriptions
- Used `ST_Extent_Agg()` instead of `ST_Extent()` for bounding boxes -- `ST_Extent` operates per-geometry, `ST_Extent_Agg` is the true aggregate function
- Sampled example values via R DuckDB connection (not CLI) to avoid Windows encoding issues with DuckDB's box-drawing table output
- GEOMETRY columns get NULL examples (WKT too large/noisy for catalogue); BLOB columns also NULL
- View descriptions generated programmatically: `_weca_vw` suffix maps to "WECA-filtered subset of {base_table}", 4 non-WECA views have explicit descriptions
- geom_valid column (lsoa_2021_lep_tbl only) has hardcoded examples "true"/"false" since it only exists in DuckLake, not source DB

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] ST_Extent returns per-geometry results, not aggregate**
- **Found during:** Task 1 (first full run verification)
- **Issue:** `ST_Extent(geom_col)` returns one row per geometry instead of aggregating all geometries into a single bounding box. Only 2 of 8 spatial tables had parsed bounding boxes because the parser expected 8 rows but got many more.
- **Fix:** Replaced `ST_Extent` with `ST_Extent_Agg` which is the proper aggregate function
- **Files modified:** scripts/refresh.R
- **Verification:** Separate test script confirmed 8/8 bounding boxes parsed correctly
- **Committed in:** 148dc64 (Task 1 commit)

**2. [Rule 1 - Bug] DuckDB CLI box-drawing output encoding fails on Windows for large result sets**
- **Found during:** Task 2 (first columns_catalogue attempt)
- **Issue:** `gsub("\u2502", "|", line)` fails with "unable to translate ... to a wide string" when DuckDB CLI outputs 411+ rows with box-drawing characters on Windows. Only 40 of 411 columns were parsed.
- **Fix:** Rewrote columns_catalogue to use source DB column metadata via R DuckDB connection (no CLI parsing needed); only DuckLake-specific operations (table creation, bounding boxes) use CLI
- **Files modified:** scripts/refresh.R
- **Verification:** Full end-to-end run: 411 columns, 398 with examples, 404 with descriptions
- **Committed in:** 47c2ec2 (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (2 bugs)
**Impact on plan:** Both fixes necessary for correctness. No scope creep.

## Issues Encountered
- DuckLake does not preserve column comments across DROP+CREATE -- used source DB metadata instead
- DuckDB CLI box-drawing character output causes encoding errors on Windows with large result sets -- avoided by using R DuckDB connection for bulk metadata queries
- First full run took ~12 minutes (dominated by 19M-row EPC table pin export); catalogue generation itself takes only ~3 seconds

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness
- Phase 5 complete: refresh pipeline + data catalogue fully operational
- Ready for Phase 6 (Analyst Documentation)
- Analysts can query `SELECT * FROM lake.datasets_catalogue` and `SELECT * FROM lake.columns_catalogue`
- Analysts can also read pinned parquet from S3 via `pin_read(board, 'datasets_catalogue')` / `pin_read(board, 'columns_catalogue')`

---
## Self-Check: PASSED

- FOUND: scripts/refresh.R
- FOUND: commit 148dc64
- FOUND: commit 47c2ec2

*Phase: 05-refresh-pipeline-and-data-catalogue*
*Completed: 2026-02-24*
