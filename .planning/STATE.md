# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** Analysts can discover and access curated, well-documented datasets from a shared catalogue without needing to know where or how the data is stored.
**Current focus:** Phase 3 in progress -- DuckLake Catalogue

## Current Position

Phase: 3 of 6 (DuckLake Catalogue)
Plan: 1 of 3 complete (03-01 complete)
Status: In progress
Last activity: 2026-02-23 -- Completed 03-01-PLAN.md (catalogue creation and table registration)

Progress: [██████░░░░░░░░] 43%

## Performance Metrics

**Velocity:**
- Total plans completed: 6
- Average duration: ~12 minutes
- Total execution time: ~66 minutes

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-aws-infrastructure | 2 | ~2 min | ~1 min |
| 02-table-export-via-pins | 3 | ~32 min | ~11 min |
| 03-ducklake-catalogue | 1 | ~31 min | ~31 min |

**Recent Trend:**
- Last 5 plans: 02-01 (~6 min), 02-02 (~21 min), 02-03 (~5 min), 03-01 (~31 min)
- Trend: S3 upload-heavy plans take longer; 03-01 uploaded 18 tables as parquet to S3

*Updated after each plan completion*

## Accumulated Context

### Decisions

Decisions are logged in PROJECT.md Key Decisions table.
Recent decisions affecting current work:

- [Roadmap]: Dual-track architecture -- DuckLake under `ducklake/` prefix, pins under `pins/` prefix, separate file lifecycles
- [Roadmap]: Non-spatial tables first, spatial isolated in Phase 4 (highest risk component)
- [Roadmap]: Phases 3 and 4 can potentially parallelise after Phase 2
- [01-02]: Used placeholder format for credentials, four verification methods (DuckDB, R, Python, AWS CLI)
- [02-01]: Spatial tables identified via BLOB/GEOMETRY/WKB column type patterns (8 spatial, 10 non-spatial)
- [02-01]: pyarrow added as explicit dependency for Python parquet reading
- [02-01]: ca_la_lookup_tbl used as interop test table (smallest non-spatial, 106 rows)
- [02-02]: Chunked pin_upload pattern established for tables with >2GB parquet output (curl upload limit workaround)
- [02-03]: Python pin_read fails on multi-file pins from pin_upload; arrow dataset fallback required
- [03-01]: Local .ducklake file required -- DuckDB cannot create database files on S3
- [03-01]: Spatial columns cast to BLOB for DuckLake compatibility (WKB_BLOB/GEOMETRY not supported)
- [03-01]: Individual CREATE TABLE used instead of COPY FROM DATABASE (spatial types cause failure)
- [03-01]: R script uses DuckDB CLI (R duckdb v1.4.4 lacks ducklake extension)

### Pending Todos

None.

### Blockers/Concerns

- [Research]: WKB_BLOB to DuckLake native geometry conversion path is LOW confidence -- needs validation spike in Phase 4
- [Phase 4]: GeoParquet added to research scope -- could unify spatial format for both pins and DuckLake instead of separate WKT/GEOMETRY paths
- [03-01]: DuckLake catalogue file is local (data/mca_env.ducklake) -- analysts need this file to attach; sharing mechanism TBD
- [03-01]: Orphaned parquet files on S3 from failed COPY FROM DATABASE attempt; cosmetic, does not affect functionality
- [03-01]: R duckdb package (v1.4.4) and DuckDB CLI (v1.4.1) version mismatch; scripts use CLI
- [RESOLVED]: pins R/Python cross-language interoperability validated in 02-01 -- custom metadata round-trips correctly
- [RESOLVED]: raw_domestic_epc_certificates_tbl (19.3M rows) exported successfully via chunked pin_upload (7 x 3M-row parquet shards)
- [RESOLVED]: All 10 non-spatial pins validated readable from both R and Python with correct metadata (02-03)
- [02-01]: s3fs version warning (cosmetic) -- may want to pin s3fs version in future
- [02-03]: Python pins library cannot pin_read multi-file pins -- analysts should use arrow/duckdb for EPC table

## Session Continuity

Last session: 2026-02-23
Stopped at: Completed 03-01-PLAN.md (DuckLake catalogue creation)
Resume action: Execute 03-02-PLAN.md (comments and views)
Resume file: None
