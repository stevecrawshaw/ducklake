# Roadmap: DuckLake

## Overview

This roadmap delivers a data sharing platform in six phases: secure AWS access first, then non-spatial table export via pins for immediate analyst value, DuckLake catalogue for SQL-based querying, isolated spatial data handling (highest risk), operational refresh pipeline with a data catalogue, and finally analyst-facing documentation. Phases 3 and 4 can execute in parallel once Phase 2 completes, since DuckLake and spatial handling are independent workstreams.

## Phases

**Phase Numbering:**
- Integer phases (1, 2, 3): Planned milestone work
- Decimal phases (2.1, 2.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

- [x] **Phase 1: AWS Infrastructure** - Read-only IAM policy and credential configuration for analysts
- [ ] **Phase 2: Table Export via Pins** - Export non-spatial tables to S3 with metadata, accessible from R and Python
- [ ] **Phase 3: DuckLake Catalogue** - Register all tables in a DuckLake catalogue with comments, time travel, and views
- [ ] **Phase 4: Spatial Data Handling** - Convert WKB_BLOB geometry columns for both pins and DuckLake consumers
- [ ] **Phase 5: Refresh Pipeline and Data Catalogue** - Repeatable re-export, version management, and queryable table-of-tables
- [ ] **Phase 6: Analyst Documentation** - Consumer guides for pins and DuckLake access patterns

## Phase Details

### Phase 1: AWS Infrastructure
**Goal**: Analysts can authenticate to AWS and the data owner has a secure foundation for all subsequent S3 operations
**Depends on**: Nothing (first phase)
**Requirements**: INFRA-01, INFRA-02
**Success Criteria** (what must be TRUE):
  1. A read-only IAM policy exists that restricts analyst AWS users to S3 read operations on the target bucket
  2. The data owner can connect DuckDB to S3 using `credential_chain` (no hardcoded keys)
  3. An analyst following the credential documentation can configure their `.aws` config and verify access
**Plans**: 2 plans

Plans:
- [x] 01-01-PLAN.md -- IAM policy, group, user, and DuckDB credential_chain verification
- [x] 01-02-PLAN.md -- Analyst credential configuration documentation

### Phase 2: Table Export via Pins
**Goal**: Analysts can discover, read, and understand non-spatial datasets from both R and Python using pins
**Depends on**: Phase 1
**Requirements**: EXPORT-01, EXPORT-02, EXPORT-03, EXPORT-05, PINS-01, PINS-02, PINS-03, PINS-04, PINS-05
**Success Criteria** (what must be TRUE):
  1. All non-spatial tables from the source DuckDB are available as parquet files on S3 under the `pins/` prefix
  2. An analyst in R can run `pin_list(board)` and see all available datasets
  3. An analyst in R can run `pin_read(board, "table_name")` and get a data frame with correct types
  4. An analyst in Python can list and read the same datasets using pins
  5. Pin metadata for each table includes the table description and column descriptions from the source DuckDB
  6. The 19M-row EPC table exports successfully without OOM or timeout
**Plans**: 3 plans

Plans:
- [x] 02-01-PLAN.md -- Metadata extraction, spatial table identification, and cross-language interop validation
- [ ] 02-02-PLAN.md -- Bulk export of all non-spatial tables as pins to S3 with metadata
- [ ] 02-03-PLAN.md -- Cross-language validation (R and Python read all pins)

### Phase 3: DuckLake Catalogue
**Goal**: Analysts can attach a shared DuckLake catalogue and query any table with SQL, including time travel and pre-built views
**Depends on**: Phase 2
**Requirements**: LAKE-01, LAKE-02, LAKE-03, LAKE-04, LAKE-05, LAKE-06, LAKE-07
**Success Criteria** (what must be TRUE):
  1. An analyst can run `ATTACH 'ducklake:s3://...'` from a fresh DuckDB session and see all 18 tables
  2. Table comments are visible via DuckLake's `COMMENT ON TABLE` facility
  3. Column comments are visible via DuckLake's `COMMENT ON COLUMN` facility
  4. An analyst can query a table at a past snapshot (time travel works)
  5. Pre-built views for common queries (e.g. WECA-area filters) are available in the catalogue
**Plans**: TBD

Plans:
- [ ] 03-01: DuckLake catalogue creation and non-spatial table registration
- [ ] 03-02: Metadata comments and view creation
- [ ] 03-03: Time travel and data change feed validation

### Phase 4: Spatial Data Handling
**Goal**: Spatial tables with WKB_BLOB geometry columns are correctly converted and accessible through both pins and DuckLake
**Depends on**: Phase 2 (pins infrastructure), Phase 3 (DuckLake catalogue)
**Requirements**: EXPORT-04
**Research scope**: Investigate GeoParquet as a potential unified format for spatial data — could replace the separate WKT (pins) and native GEOMETRY (DuckLake) paths if pins compatibility and analyst tooling (sf, geopandas) support it via `pin_upload`/`pin_download`.
**Success Criteria** (what must be TRUE):
  1. Geometry columns are stored as native GEOMETRY type in DuckLake (not raw BLOB)
  2. Geometry columns are accessible in pins exports and readable by R `sf` and Python `geopandas` (format TBD pending GeoParquet research — could be WKT text or GeoParquet)
  3. An analyst can roundtrip a geometry column: read from pins/DuckLake, convert to spatial object, and plot it
**Plans**: TBD

Plans:
- [ ] 04-01: GeoParquet feasibility spike and spatial format decision
- [ ] 04-02: Spatial table export (format per 04-01 findings)

### Phase 5: Refresh Pipeline and Data Catalogue
**Goal**: The data owner can re-export updated data with a single command, and analysts can discover what datasets exist without asking
**Depends on**: Phase 4
**Requirements**: REFRESH-01, REFRESH-02, REFRESH-03, CAT-01, CAT-02, CAT-03
**Success Criteria** (what must be TRUE):
  1. Running the refresh script re-exports all tables from source DuckDB to both pins and DuckLake
  2. After a refresh, DuckLake snapshots are retained so analysts can still query previous versions
  3. After a refresh, pins versions are updated so analysts see the new data
  4. A queryable table-of-tables exists listing all datasets with descriptions, column details, row counts, and last updated dates
**Plans**: TBD

Plans:
- [ ] 05-01: Refresh pipeline (re-export orchestration)
- [ ] 05-02: Data catalogue manifest

### Phase 6: Analyst Documentation
**Goal**: An analyst can go from zero to querying data independently, using only the provided documentation
**Depends on**: Phase 5
**Requirements**: INFRA-03, INFRA-04
**Success Criteria** (what must be TRUE):
  1. Documentation exists showing how to access data via pins in both R and Python (with working code examples)
  2. Documentation exists showing how to attach and query the DuckLake catalogue (with working code examples)
  3. An analyst unfamiliar with the platform can follow the docs and successfully read a dataset within 10 minutes
**Plans**: TBD

Plans:
- [ ] 06-01: Pins access guide (R and Python)
- [ ] 06-02: DuckLake access guide

## Progress

**Execution Order:**
Phases execute in numeric order: 1 -> 2 -> 3 -> 4 -> 5 -> 6
Note: Phases 3 and 4 could potentially execute in parallel after Phase 2.

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. AWS Infrastructure | 2/2 | Complete | 2026-02-22 |
| 2. Table Export via Pins | 1/3 | In progress | - |
| 3. DuckLake Catalogue | 0/3 | Not started | - |
| 4. Spatial Data Handling | 0/1 | Not started | - |
| 5. Refresh Pipeline and Data Catalogue | 0/2 | Not started | - |
| 6. Analyst Documentation | 0/2 | Not started | - |

---
*Roadmap created: 2026-02-22*
*Last updated: 2026-02-22*
