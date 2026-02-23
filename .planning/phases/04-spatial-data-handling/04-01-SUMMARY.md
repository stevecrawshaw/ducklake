# Phase 4 Plan 1: Spatial Pipeline Spike Summary

**One-liner:** Full spatial pipeline validated end-to-end: WKB_BLOB -> DuckLake GEOMETRY -> GeoParquet pin -> R sf / Python geopandas roundtrip with bdline_ua_lep_diss_tbl (1 row).

## Metadata

| Field | Value |
|-------|-------|
| Phase | 04-spatial-data-handling |
| Plan | 01 |
| Subsystem | spatial-pipeline |
| Started | 2026-02-23T10:51:39Z |
| Completed | 2026-02-23T10:58:52Z |
| Duration | ~7 minutes |
| Tasks | 1/1 |
| Tags | spatial, geometry, geoparquet, ducklake, pins, sf, geopandas |

## Dependency Graph

- **Requires:** Phase 3 (DuckLake catalogue with BLOB spatial columns)
- **Provides:** Validated spatial conversion pipeline, spike scripts as reference patterns
- **Affects:** 04-02 (batch spatial conversion of all 8 tables)

## Tech Stack

### Added
- `geopandas` 1.1.2 (Python, for GeoParquet consumption)
- `pyogrio` 0.12.1, `pyproj` 3.7.2, `shapely` 2.1.2 (geopandas dependencies)

### Patterns Established
- DuckLake GEOMETRY creation via `ST_GeomFromWKB(shape)` from WKB_BLOB source
- GeoParquet export via DuckDB `COPY TO` (automatic GeoParquet 1.0.0 metadata)
- GeoParquet pin upload with spatial metadata (`spatial=TRUE`, `geometry_column`, `geometry_type`, `crs`)
- R consumption: `arrow::read_parquet()` + `sf::st_as_sf()` (sfarrow fails on missing CRS)
- Python consumption: `geopandas.read_parquet()` via `board_s3("bucket/pins")` pattern
- CRS must be set explicitly after reading (`sf::st_set_crs(obj, 27700)`)

## Key Files

### Created
| File | Purpose |
|------|---------|
| `scripts/spike_spatial.sql` | SQL for DuckLake GEOMETRY recreation and GeoParquet export |
| `scripts/spike_spatial.R` | R wrapper: DuckDB CLI execution, pin upload, R/Python validation |

### Modified
| File | Change |
|------|--------|
| `pyproject.toml` | Added geopandas dependency |
| `uv.lock` | Updated with geopandas and dependencies |

## Decisions Made

| Decision | Context | Rationale |
|----------|---------|-----------|
| Use `arrow::read_parquet + sf::st_as_sf` over sfarrow | sfarrow fails with "Required 'geo' metadata item 'crs' not found" | DuckDB COPY TO writes GeoParquet 1.0.0 without CRS; sfarrow requires CRS in metadata |
| Python pins uses `board_s3("bucket/pins")` not `board_s3("bucket", prefix="pins/")` | Python pins API differs from R | `prefix` is not a parameter in Python pins `board_s3()` constructor |
| CRS set explicitly after read, not embedded in GeoParquet | DuckDB GEOMETRY is CRS-agnostic | Known limitation; document for analysts, track CRS in pin metadata |

## Validation Results

All 7 spike checks passed:

| Check | Result | Detail |
|-------|--------|--------|
| DuckDB CLI execution | PASS | Extensions loaded, tables attached |
| GEOMETRY type (not BLOB) | PASS | `typeof(shape)` returns GEOMETRY |
| Spatial SQL (ST_Area) | PASS | Area = 1,390,386,551.65 sqm |
| GeoParquet export | PASS | 24.8 KB file with GeoParquet 1.0.0 metadata |
| Pin upload to S3 | PASS | `spatial=TRUE`, `crs=EPSG:27700` in metadata |
| R sf roundtrip | PASS | sf object, POLYGON, CRS set to EPSG:27700 |
| Python geopandas roundtrip | PASS | GeoDataFrame, Polygon, CRS=OGC:CRS84 |

**Note on Python CRS:** geopandas reports CRS as `OGC:CRS84` rather than the source EPSG:27700. This is because DuckDB does not write CRS into GeoParquet metadata, and geopandas defaults to CRS84 when reading GeoParquet without CRS. Analysts should set CRS explicitly: `gdf.set_crs(epsg=27700)`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] geopandas not installed**
- **Found during:** Task 1, Python validation step
- **Issue:** `No module named 'geopandas'` -- dependency not in project
- **Fix:** `uv add geopandas` (added 1.1.2 + 3 dependencies)
- **Files modified:** pyproject.toml, uv.lock
- **Commit:** 54d797c

**2. [Rule 1 - Bug] Python pins board_s3 API mismatch**
- **Found during:** Task 1, Python validation step
- **Issue:** Plan specified `board_s3("bucket", prefix="pins/", region="eu-west-2")` but Python pins API uses `board_s3("bucket/pins", versioned=True)` with `AWS_DEFAULT_REGION` env var
- **Fix:** Updated Python code generation to match existing `validate_pins.py` pattern
- **Files modified:** scripts/spike_spatial.R
- **Commit:** 54d797c

**3. [Rule 3 - Blocking] DuckLake file locked by lingering DuckDB process**
- **Found during:** Task 1, first execution attempt
- **Issue:** PID 18380 held exclusive lock on `data/mca_env.ducklake`
- **Fix:** Killed process (`taskkill /PID 18380 /F`), re-ran successfully
- **No code change required** -- Windows file locking, documented in research as Pitfall 4

## Commits

| Hash | Message |
|------|---------|
| 54d797c | feat(04-01): spatial pipeline spike with bdline_ua_lep_diss_tbl |

## Next Phase Readiness

**Safe to proceed with 04-02** (batch conversion of all 8 spatial tables).

Key findings for 04-02:
- sfarrow cannot be used for R consumption (CRS gap). Use `arrow::read_parquet + sf::st_as_sf` instead.
- Python pins board path format: `board_s3("stevecrawshaw-bucket/pins")` (no separate prefix parameter).
- No chunking needed -- even the largest spatial table (687K rows) is only ~18MB as GeoParquet.
- CRS is not embedded in GeoParquet by DuckDB. Document in pin metadata and column comments. Analysts must set CRS explicitly.
- The existing non-spatial pin version is superseded by the GeoParquet version (versioned board handles this).
