# Project State

## Project Reference

See: .planning/PROJECT.md (updated 2026-02-22)

**Core value:** Analysts can discover and access curated, well-documented datasets from a shared catalogue without needing to know where or how the data is stored.
**Current focus:** Phase 2 - Table Export via Pins

## Current Position

Phase: 2 of 6 (Table Export via Pins) — In progress
Plan: 2 of 3 complete (02-02 complete)
Status: In progress
Last activity: 2026-02-22 -- Completed 02-02-PLAN.md (bulk pin export, 26.4M rows)

Progress: [████░░░░░░] 33%

## Performance Metrics

**Velocity:**
- Total plans completed: 2
- Average duration: ~3.5 minutes
- Total execution time: ~7 minutes

**By Phase:**

| Phase | Plans | Total | Avg/Plan |
|-------|-------|-------|----------|
| 01-aws-infrastructure | 1 | ~1 min | ~1 min |
| 02-table-export-via-pins | 2 | ~27 min | ~13.5 min |

**Recent Trend:**
- Last 5 plans: 01-02 (~1 min), 02-01 (~6 min), 02-02 (~21 min)
- Trend: increasing as tasks involve real I/O and large data volumes

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

### Pending Todos

None.

### Blockers/Concerns

- [Research]: WKB_BLOB to DuckLake native geometry conversion path is LOW confidence -- needs validation spike in Phase 4
- [Phase 4]: GeoParquet added to research scope -- could unify spatial format for both pins and DuckLake instead of separate WKT/GEOMETRY paths
- [RESOLVED]: pins R/Python cross-language interoperability validated in 02-01 -- custom metadata round-trips correctly
- [RESOLVED]: raw_domestic_epc_certificates_tbl (19.3M rows) exported successfully via chunked pin_upload (7 x 3M-row parquet shards)
- [02-01]: s3fs version warning (cosmetic) -- may want to pin s3fs version in future

## Session Continuity

Last session: 2026-02-22
Stopped at: Completed 02-02-PLAN.md
Resume action: Execute 02-03-PLAN.md (cross-language validation)
Resume file: None
