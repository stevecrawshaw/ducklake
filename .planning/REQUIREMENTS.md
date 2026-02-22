# Requirements: DuckLake

**Defined:** 2026-02-22
**Core Value:** Analysts can discover, understand, and query shared datasets from R or Python without asking the data owner.

## v1 Requirements

### Data Export

- [ ] **EXPORT-01**: All 18 DuckDB tables exported as parquet files to S3 bucket
- [ ] **EXPORT-02**: Table-level comments from source DuckDB preserved through export
- [ ] **EXPORT-03**: Column-level comments from source DuckDB preserved through export
- [ ] **EXPORT-04**: WKB_BLOB geometry columns converted to native geometry types during export
- [ ] **EXPORT-05**: Large tables (19M+ row EPCs) exported without OOM or timeout failures

### Pins Access

- [ ] **PINS-01**: Analyst can list available datasets from R using `pin_list(board)`
- [ ] **PINS-02**: Analyst can read any table from R using `pin_read(board, "table_name")`
- [ ] **PINS-03**: Analyst can list available datasets from Python using pins
- [ ] **PINS-04**: Analyst can read any table from Python using pins
- [ ] **PINS-05**: Pin metadata includes table description and column descriptions

### DuckLake Catalogue

- [ ] **LAKE-01**: DuckLake catalogue created on S3 with all 18 tables registered
- [ ] **LAKE-02**: Analyst can attach DuckLake catalogue and query tables with SQL
- [ ] **LAKE-03**: Table comments visible via `COMMENT ON TABLE` in DuckLake
- [ ] **LAKE-04**: Column comments visible via `COMMENT ON COLUMN` in DuckLake
- [ ] **LAKE-05**: Analyst can query data at a past point in time (time travel)
- [ ] **LAKE-06**: Analyst can see what changed between data refreshes (data change feed)
- [ ] **LAKE-07**: Pre-built views available for common queries (e.g. WECA-area filters)

### Infrastructure

- [ ] **INFRA-01**: Read-only IAM policy created for analyst AWS users
- [ ] **INFRA-02**: Documentation for analysts on how to configure AWS credentials
- [ ] **INFRA-03**: Documentation for analysts on how to access data via pins (R and Python)
- [ ] **INFRA-04**: Documentation for analysts on how to attach and query DuckLake

### Data Catalogue

- [ ] **CAT-01**: Queryable table-of-tables listing all available datasets with descriptions
- [ ] **CAT-02**: Each dataset listing includes column names, types, and descriptions
- [ ] **CAT-03**: Each dataset listing includes row count and last updated date

### Refresh Pipeline

- [ ] **REFRESH-01**: Script to re-export updated tables from source DuckDB to S3
- [ ] **REFRESH-02**: Refresh preserves DuckLake history (snapshots retained for time travel)
- [ ] **REFRESH-03**: Refresh updates pins versions so analysts can see new data

## v2 Requirements

### Advanced Features

- **ADV-01**: Table partitioning for large EPC table if query performance is poor
- **ADV-02**: PostgreSQL metadata backend if concurrent write access needed
- **ADV-03**: Schema evolution documentation for analysts when columns change
- **ADV-04**: Automated scheduled refresh (cron/scheduled task)

## Out of Scope

| Feature | Reason |
|---------|--------|
| Web UI / data browser | Massive engineering effort for small team; analysts have R/Python notebooks |
| Real-time data sync | Source data updates quarterly; batch refresh is sufficient |
| Write access for analysts | Creates data governance problems; analysts work locally |
| Fine-grained per-table access control | All tables intended for whole team; internal government statistics |
| DuckLake encryption | S3 server-side encryption sufficient; not PII data |
| Data inlining | Experimental DuckLake feature; adds complexity for marginal benefit |

## Traceability

| Requirement | Phase | Status |
|-------------|-------|--------|
| EXPORT-01 | Phase 2 | Pending |
| EXPORT-02 | Phase 2 | Pending |
| EXPORT-03 | Phase 2 | Pending |
| EXPORT-04 | Phase 4 | Pending |
| EXPORT-05 | Phase 2 | Pending |
| PINS-01 | Phase 2 | Pending |
| PINS-02 | Phase 2 | Pending |
| PINS-03 | Phase 2 | Pending |
| PINS-04 | Phase 2 | Pending |
| PINS-05 | Phase 2 | Pending |
| LAKE-01 | Phase 3 | Pending |
| LAKE-02 | Phase 3 | Pending |
| LAKE-03 | Phase 3 | Pending |
| LAKE-04 | Phase 3 | Pending |
| LAKE-05 | Phase 3 | Pending |
| LAKE-06 | Phase 3 | Pending |
| LAKE-07 | Phase 3 | Pending |
| INFRA-01 | Phase 1 | Pending |
| INFRA-02 | Phase 1 | Pending |
| INFRA-03 | Phase 6 | Pending |
| INFRA-04 | Phase 6 | Pending |
| CAT-01 | Phase 5 | Pending |
| CAT-02 | Phase 5 | Pending |
| CAT-03 | Phase 5 | Pending |
| REFRESH-01 | Phase 5 | Pending |
| REFRESH-02 | Phase 5 | Pending |
| REFRESH-03 | Phase 5 | Pending |

**Coverage:**
- v1 requirements: 27 total
- Mapped to phases: 27
- Unmapped: 0

---
*Requirements defined: 2026-02-22*
*Last updated: 2026-02-22 after roadmap creation*
