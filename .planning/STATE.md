# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** Analysts can discover and access curated, well-documented datasets from a shared catalogue without needing to know where or how the data is stored.
**Current focus:** Phase 5 in progress -- Refresh Pipeline and Data Catalogue

## Current Position

Phase: 5 of 6 (Refresh Pipeline and Data Catalogue)
Plan: 1 of 2 complete
Status: In progress
Last activity: 2026-02-24 -- Completed 05-01-PLAN.md (unified refresh pipeline)

Progress: [████████████░░░] 85%

## Performance Metrics

**Velocity:**
- Total plans completed: 10
- Average duration: ~11 minutes
- Total execution time: ~109 minutes

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-aws-infrastructure | 2 | ~2 min | ~1 min |
| 02-table-export-via-pins | 3 | ~32 min | ~11 min |
| 03-ducklake-catalogue | 3 | ~43 min | ~14 min |
| 04-spatial-data-handling | 2 | ~10 min | ~5 min |
| 05-refresh-pipeline | 1 | ~26 min | ~26 min |

**Recent Trend:**
- Last 5 plans: 03-02 (~7 min), 03-03 (~5 min), 04-01 (~7 min), 04-02 (~3 min), 05-01 (~26 min)
- Trend: Refresh pipeline slower due to 18-table re-export (217s DuckLake + 400s pins including 19M-row EPC)

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
- [03-02]: Column comments filtered to base tables only (403 of 663; 260 on views excluded)
- [03-02]: weca_lep_la_vw returns 4 rows (North Somerset is 4th WECA LEP LA, not additional)
- [03-02]: 3 spatial-dependent views deferred to Phase 4
- [03-03]: Time-based retention (90 days) chosen over version-count -- DuckLake snapshots are database-wide, not per-table
- [04-01]: sfarrow fails on GeoParquet from DuckDB (missing CRS in metadata) -- use arrow::read_parquet + sf::st_as_sf instead
- [04-01]: Python pins board_s3 uses "bucket/prefix" path format, not separate prefix parameter
- [04-01]: CRS not embedded in GeoParquet by DuckDB -- track in pin metadata, analysts set explicitly
- [04-01]: geopandas added as Python dependency for spatial pin consumption
- [04-02]: Export from source DB (not lake) for GeoParquet -- avoids S3 round-trip
- [04-02]: geom_valid flag preserves original data -- analysts decide how to handle invalid geometries
- [05-01]: Batch DuckLake operations: all 18 DROP+CREATE in single SQL file, one CLI call
- [05-01]: Batch row count validation via UNION ALL query (one CLI call instead of 18)
- [05-01]: DuckDB CLI box-drawing output parsed by replacing unicode pipe chars and splitting

### Pending Todos

None.

### Blockers/Concerns

- [RESOLVED]: WKB_BLOB to DuckLake native geometry conversion validated in 04-01 spike -- ST_GeomFromWKB works, GEOMETRY type confirmed
- [RESOLVED]: GeoParquet pipeline validated -- DuckDB COPY TO produces GeoParquet 1.0.0, R and Python can read
- [03-01]: DuckLake catalogue file is local (data/mca_env.ducklake) -- analysts need this file to attach; sharing mechanism TBD
- [03-01]: Orphaned parquet files on S3 from failed COPY FROM DATABASE attempt; cosmetic, does not affect functionality
- [03-01]: R duckdb package (v1.4.4) and DuckDB CLI (v1.4.1) version mismatch; scripts use CLI
- [04-01]: sfarrow incompatible with DuckDB GeoParquet (no CRS in geo metadata) -- use arrow + sf instead
- [04-01]: Python geopandas reports CRS as OGC:CRS84 when GeoParquet has no CRS metadata -- analysts must set CRS explicitly
- [02-01]: s3fs version warning (cosmetic) -- may want to pin s3fs version in future
- [02-03]: Python pins library cannot pin_read multi-file pins -- analysts should use arrow/duckdb for EPC table

## Session Continuity

Last session: 2026-02-24
Stopped at: Completed 05-01-PLAN.md (unified refresh pipeline)
Resume action: Execute 05-02-PLAN.md (Data Catalogue)
Resume file: .planning/phases/05-refresh-pipeline-and-data-catalogue/05-02-PLAN.md
