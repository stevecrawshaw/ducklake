---
phase: 03-ducklake-catalogue
plan: 02
subsystem: ducklake-catalogue
tags: [ducklake, comments, views, weca, duckdb]
requires: [03-01]
provides: [ducklake-comments-403-columns, ducklake-12-views]
affects: [03-03, phase-04]
tech-stack:
  added: []
  patterns: [comment-extraction-from-source, weca-filtered-views]
key-files:
  created:
    - scripts/apply_comments.R
    - scripts/create_views.sql
  modified: []
key-decisions:
  - Column comments filtered to base tables only (403 of 663 source comments; 260 on views excluded)
  - weca_lep_la_vw returns 4 rows (not 5 as plan estimated; North Somerset is the 4th, not additional)
  - Spatial-dependent views deferred to Phase 4 (ca_boundaries_inc_ns_vw, epc_domestic_lep_vw, epc_non_domestic_lep_vw)
duration: ~7 min
completed: 2026-02-23
---

# Phase 03 Plan 02: Comments and Views Summary

Table/column comments extracted from source DuckDB and applied to DuckLake catalogue; 4 non-spatial source views and 8 WECA-filtered views created via DuckDB CLI.

## Performance

- Duration: ~7 minutes
- 2 tasks, both completed on first attempt

## Accomplishments

1. Applied 18 table comments verbatim from source database
2. Applied 403 column comments (all base-table columns; view columns correctly excluded)
3. Created 4 non-spatial source views: ca_la_lookup_inc_ns_vw, weca_lep_la_vw, ca_la_ghg_emissions_sub_sector_ods_vw, epc_domestic_vw
4. Created 8 WECA-filtered views for tables with LA code columns
5. All 12 views queryable and returning correct data

## Task Commits

| Task | Name | Commit | Key Files |
|------|------|--------|-----------|
| 1 | Apply table and column comments to DuckLake catalogue | 3a7bcc6 | scripts/apply_comments.R |
| 2 | Create non-spatial source views and WECA-filtered views | 9e16b1d | scripts/create_views.sql, scripts/apply_comments.R |

## Files Created/Modified

### Created
- `scripts/apply_comments.R` -- Extracts comments from source DuckDB and applies to DuckLake; also executes view creation SQL
- `scripts/create_views.sql` -- SQL definitions for 4 source views and 8 WECA-filtered views

### Modified
None.

## Decisions Made

### 1. Column comments filtered to base tables only
- **Context:** Source database has 663 column comments, but 260 are on views (not tables)
- **Decision:** Filter column comments to base tables only via JOIN with duckdb_tables(), yielding 403 applicable comments
- **Impact:** Cleaner execution with no error noise. View-column comments will be applied when views are created in Phase 4

### 2. weca_lep_la_vw returns 4 rows, not 5
- **Context:** Plan estimated 5 rows (4 WECA + North Somerset separately)
- **Decision:** Correct count is 4. North Somerset (E06000024) is one of the 4 WECA LEP authorities, not additional to them. The ca_la_lookup_tbl has 3 combined authority members; the UNION adds North Somerset as the 4th.
- **Impact:** None -- the data is correct

### 3. Spatial-dependent views deferred
- **Context:** 3 source views depend on spatial functions (st_transform, geopoint_from_blob)
- **Decision:** Skip entirely, defer to Phase 4
- **Impact:** epc_domestic_lep_vw, epc_non_domestic_lep_vw, ca_boundaries_inc_ns_vw not created yet

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Initial script applied comments to view names causing errors**
- **Found during:** Task 1, first run
- **Issue:** Source duckdb_columns() returns columns for both tables and views; COMMENT ON for view names failed with "Table does not exist"
- **Fix:** Added INNER JOIN with duckdb_tables() to filter column comments to base tables only
- **Files modified:** scripts/apply_comments.R
- **Commit:** 3a7bcc6

## Verification Results

| Check | Result |
|-------|--------|
| Table comments visible | 18/18 tables have comments |
| Column comments visible | 403 columns have comments |
| Source views queryable | All 4 return data correctly |
| WECA views filter correctly | All 8 filter to WECA LA codes |
| Spatial views not created | Confirmed -- 0 spatial views |
| epc_domestic_vw derived columns | LODGEMENT_YEAR, CONSTRUCTION_EPOCH, TENURE_CLEAN all computing |

## Next Phase Readiness

### For 03-03 (Time Travel and Snapshots)
- **Ready:** Catalogue fully commented with 12 views
- **Note:** Views are stored in the catalogue metadata, not as parquet -- time travel applies to table data only

### For Phase 4 (Spatial Data)
- **Note:** 3 spatial-dependent views still need creation (ca_boundaries_inc_ns_vw, epc_domestic_lep_vw, epc_non_domestic_lep_vw)
- **Note:** 260 view-column comments from source still unapplied (depend on views existing first)
