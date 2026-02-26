---
phase: 03-ducklake-catalogue
plan: 01
subsystem: ducklake-catalogue
tags: [ducklake, duckdb, s3, parquet, catalogue]
requires: [phase-02]
provides: [ducklake-catalogue-18-tables]
affects: [03-02, 03-03, phase-04]
tech-stack:
  added: [ducklake-extension, spatial-extension]
  patterns: [local-catalogue-s3-data, blob-cast-spatial]
key-files:
  created:
    - scripts/create_ducklake.sql
    - scripts/create_ducklake.R
    - data/mca_env.ducklake
  modified: []
key-decisions:
  - Local catalogue file with S3 data path (S3-hosted .ducklake not supported)
  - Spatial columns cast to BLOB (DuckLake does not support WKB_BLOB or GEOMETRY types)
  - Individual CREATE TABLE instead of COPY FROM DATABASE (spatial types cause failure)
  - DuckDB CLI execution from R (R duckdb package v1.4.4 lacks ducklake extension)
duration: ~31 min
completed: 2026-02-23
---

# Phase 03 Plan 01: DuckLake Catalogue Creation Summary

DuckLake catalogue with all 18 tables registered (10 non-spatial + 8 spatial with BLOB-cast geometry columns), local metadata file with S3 parquet data storage.

## Performance

- Duration: ~31 minutes (bulk of time uploading 19M-row EPC table + spatial tables to S3 as parquet)
- All 18 tables registered in a single execution pass

## Accomplishments

1. Created DuckLake catalogue at `data/mca_env.ducklake` with data at `s3://stevecrawshaw-bucket/ducklake/data/`
2. Registered all 10 non-spatial tables directly
3. Registered all 8 spatial tables with WKB_BLOB/GEOMETRY columns cast to BLOB
4. Verified all 18 tables queryable from a fresh DuckDB session
5. Spot-checked row counts: ca_la_lookup_tbl (106), boundary_lookup_tbl (2,720,556), la_ghg_emissions_tbl (559,215), raw_domestic_epc_certificates_tbl (19,322,638), open_uprn_lep_tbl (687,143)

## Task Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Create DuckLake catalogue and register all 18 tables | 7484d62 | scripts/create_ducklake.sql, scripts/create_ducklake.R |

## Files Created/Modified

### Created
- `scripts/create_ducklake.sql` -- SQL script for catalogue creation and table registration
- `scripts/create_ducklake.R` -- R wrapper that executes SQL via DuckDB CLI with verification
- `data/mca_env.ducklake` -- DuckLake catalogue metadata file (not committed, runtime artefact)

### Modified
None.

## Decisions Made

### 1. Local catalogue file, not S3-hosted
- **Context:** Research open question 1 -- can the .ducklake file live on S3?
- **Decision:** No. DuckDB cannot create a new database file on S3. The error is: "Cannot open database in read-only mode: database does not exist". The catalogue metadata file must be local.
- **Impact:** Analysts need access to the local .ducklake file to attach the catalogue. For sharing, the file can be copied to S3 and downloaded, or hosted on a shared network drive. Plan 03-02/03-03 may address this.

### 2. Spatial columns cast to BLOB
- **Context:** DuckLake's `CREATE TABLE AS SELECT` fails with "Unsupported user-defined type" for WKB_BLOB columns and "Unimplemented type for cast (GEOMETRY -> WKB_BLOB)" for GEOMETRY columns.
- **Decision:** Cast all spatial columns to BLOB. The binary geometry data is preserved exactly; only the type annotation changes.
- **Impact:** Phase 4 will need to handle converting BLOB back to proper geometry types if spatial queries are needed.

### 3. Individual table creation instead of COPY FROM DATABASE
- **Context:** `COPY FROM DATABASE source TO lake` fails with "Unsupported user-defined type" due to spatial columns.
- **Decision:** Create each of the 18 tables individually via `CREATE TABLE lake.X AS SELECT * FROM source.X`.
- **Impact:** More verbose SQL but full control over type casting per table.

### 4. DuckDB CLI execution from R
- **Context:** The R duckdb package (v1.4.4) cannot install the ducklake extension (segfault on INSTALL, extension not found for v1.4.4 platform). The DuckDB CLI (v1.4.1) has ducklake installed and working.
- **Decision:** R script writes SQL to a temp file and executes via `duckdb -init` CLI command.
- **Impact:** R script depends on DuckDB CLI being on PATH. The `-init` flag reads and executes the SQL file before running the `-c` command.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] S3-hosted .ducklake file not supported**
- **Found during:** Task 1, step 4
- **Issue:** `ATTACH 'ducklake:s3://...'` fails because DuckDB cannot create a new database file on S3
- **Fix:** Used local catalogue file (`data/mca_env.ducklake`) with S3 DATA_PATH
- **Files modified:** scripts/create_ducklake.sql

**2. [Rule 3 - Blocking] COPY FROM DATABASE fails on spatial types**
- **Found during:** Task 1, step 6
- **Issue:** `COPY FROM DATABASE source TO lake` returns "Unsupported user-defined type"
- **Fix:** Individual `CREATE TABLE` statements for all 18 tables, with BLOB cast for spatial columns
- **Files modified:** scripts/create_ducklake.sql

**3. [Rule 3 - Blocking] R duckdb package lacks ducklake extension**
- **Found during:** Task 1, initial execution
- **Issue:** R duckdb v1.4.4 segfaults on `INSTALL ducklake` and cannot find extensions for its platform
- **Fix:** R script executes SQL via DuckDB CLI (`duckdb -init`) instead of R's `dbExecute`
- **Files modified:** scripts/create_ducklake.R

**4. [Rule 1 - Bug] Windows path escaping in R system calls**
- **Found during:** Task 1, R script execution
- **Issue:** Windows backslash paths in temp files cause DuckDB CLI to misinterpret arguments
- **Fix:** Write SQL to project-local temp file and use `duckdb -init` with relative path
- **Files modified:** scripts/create_ducklake.R

## Issues Encountered

1. Plan states ca_la_lookup_tbl has 216 rows; actual count is 106. Used actual value.
2. Orphaned parquet files from failed COPY FROM DATABASE attempt remain on S3 under `ducklake/data/`. These do not affect the new catalogue but waste storage. Could be cleaned via AWS CLI.

## Next Phase Readiness

### For 03-02 (Comments and Views)
- **Ready:** All 18 tables exist in the catalogue
- **Prerequisite met:** Tables are queryable and can receive COMMENT ON statements
- **Note:** The .ducklake file is local at `data/mca_env.ducklake`; scripts must reference this path

### For Phase 4 (Spatial Data)
- **Note:** Spatial columns stored as BLOB, not native geometry types. Phase 4 must cast back to GEOMETRY/WKB_BLOB or use GeoParquet.
