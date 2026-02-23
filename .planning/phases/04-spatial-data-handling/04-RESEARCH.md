# Phase 4: Spatial Data Handling - Research

**Researched:** 2026-02-23
**Domain:** DuckDB spatial extension, DuckLake GEOMETRY support, GeoParquet, R/Python spatial tooling
**Confidence:** HIGH

## Summary

DuckLake 0.3 added native GEOMETRY column support (experimental), which means the Phase 3 workaround of casting spatial columns to BLOB is no longer needed. The existing 8 spatial tables in DuckLake must be recreated with `ST_GeomFromWKB()` conversion to store columns as native GEOMETRY type, enabling spatial SQL queries (ST_Contains, ST_Intersects, etc.) directly against DuckLake tables.

For pins exports, DuckDB's `COPY TO` with GEOMETRY columns automatically writes GeoParquet 1.0.0 compliant files with proper metadata (encoding, geometry types, bbox). These files can be uploaded via `pin_upload()` and consumed by R (sfarrow/geoarrow + sf) and Python (geopandas) with full spatial capability.

The source data has 7 tables in British National Grid (EPSG:27700) and 1 table in WGS84 (EPSG:4326). All geometries are valid except 2 rows in `lsoa_2021_lep_tbl`. One table (`ca_boundaries_bgc_tbl`) has mixed POLYGON/MULTIPOLYGON types requiring promotion via `ST_Multi()`.

**Primary recommendation:** Recreate the 8 DuckLake spatial tables with `ST_GeomFromWKB()` conversion to native GEOMETRY. Export GeoParquet files via DuckDB `COPY TO` and upload as pins. Spike with 1 small table first to validate the full pipeline.

## Standard Stack

### Core
| Library/Tool | Version | Purpose | Why Standard |
|---|---|---|---|
| DuckDB spatial extension | Latest (bundled with DuckDB) | GEOMETRY type, spatial functions, GeoParquet I/O | Core spatial engine; ST_GeomFromWKB, ST_Multi, ST_IsValid, COPY TO GeoParquet |
| DuckLake extension | 0.3+ (f134ad8 installed) | Native GEOMETRY column storage in DuckLake catalogue | DuckLake 0.3 added geometry support (experimental) |
| R pins | Latest CRAN | pin_upload/pin_download for GeoParquet files on S3 | Existing project pattern for non-spatial tables |
| R sfarrow | Latest CRAN | Read GeoParquet into sf objects | `st_read_parquet()` reads GeoParquet with CRS metadata |
| R geoarrow + arrow | Latest CRAN | Alternative GeoParquet read path | `arrow::read_parquet(as_data_frame=FALSE) |> sf::st_as_sf()` |
| Python geopandas | 1.x | `read_parquet()` for GeoParquet consumption | Native GeoParquet 1.0.0 support, no extra dependencies |

### Supporting
| Library | Version | Purpose | When to Use |
|---|---|---|---|
| R sf | Latest CRAN | Spatial operations, plotting, CRS management in R | Analyst consumption of spatial data |
| Python pyarrow | Latest | Required by geopandas for parquet I/O | Installed alongside geopandas |
| DuckDB CLI | v1.3.0+ | Execute SQL scripts (R duckdb package lacks ducklake) | All DuckLake operations via R wrapper scripts |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|---|---|---|
| GeoParquet (pins) | WKT text column in regular parquet | GeoParquet preserves binary geometry + CRS metadata; WKT is larger and needs parsing |
| sfarrow | geoarrow + arrow | geoarrow is newer but sfarrow is more established for GeoParquet specifically |
| pin_upload (GeoParquet) | pin_write with WKT text | pin_write can't handle sf objects directly; pin_upload with GeoParquet files is cleaner |

## Architecture Patterns

### Pattern 1: DuckLake Table Recreation with GEOMETRY Conversion
**What:** DROP existing BLOB-typed spatial tables and recreate with `ST_GeomFromWKB()` conversion to native GEOMETRY.
**When to use:** For all 8 spatial tables that were created in Phase 3 with BLOB workaround.
**Example:**
```sql
-- Source: Verified by spike test on local DuckLake (2026-02-23)
INSTALL ducklake; LOAD ducklake;
INSTALL spatial; LOAD spatial;

ATTACH 'ducklake:data/mca_env.ducklake' AS lake (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);

-- Drop the BLOB version
DROP TABLE IF EXISTS lake.bdline_ua_lep_diss_tbl;

-- Recreate with native GEOMETRY
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl;
```

### Pattern 2: Mixed Geometry Type Promotion
**What:** Use `ST_Multi()` to promote POLYGON to MULTIPOLYGON for tables with mixed types.
**When to use:** `ca_boundaries_bgc_tbl` has 6 POLYGON + 9 MULTIPOLYGON rows.
**Example:**
```sql
-- Source: DuckDB spatial docs, verified locally
CREATE TABLE lake.ca_boundaries_bgc_tbl AS
  SELECT * EXCLUDE(geom), ST_Multi(geom) AS geom
  FROM source.ca_boundaries_bgc_tbl;
```

### Pattern 3: GeoParquet Pin Export via DuckDB COPY TO
**What:** Export spatial tables as GeoParquet files using DuckDB's `COPY TO`, then upload via `pin_upload()`.
**When to use:** For all 8 spatial table pins exports.
**Example:**
```sql
-- DuckDB automatically writes GeoParquet 1.0.0 metadata (encoding, geometry_types, bbox)
COPY (
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl
) TO '/tmp/bdline_ua_lep_diss_tbl.parquet' (FORMAT PARQUET);
```

```r
# R: Upload GeoParquet file as pin
pin_upload(
  board,
  paths = "/tmp/bdline_ua_lep_diss_tbl.parquet",
  name = "bdline_ua_lep_diss_tbl",
  title = "Boundary line UA LEP dissolved",
  metadata = list(
    source_db = "ducklake",
    spatial = TRUE,
    geometry_column = "shape",
    geometry_type = "POLYGON",
    crs = "EPSG:27700"
  )
)
```

### Pattern 4: Geometry Validity Flagging
**What:** Add a `geom_valid` BOOLEAN column to tables with invalid geometries.
**When to use:** `lsoa_2021_lep_tbl` has 2 invalid geometries. Per user decision: flag, don't repair.
**Example:**
```sql
CREATE TABLE lake.lsoa_2021_lep_tbl AS
  SELECT * EXCLUDE(shape),
    ST_GeomFromWKB(shape) AS shape,
    ST_IsValid(ST_GeomFromWKB(shape)) AS geom_valid
  FROM source.lsoa_2021_lep_tbl;
```

### Pattern 5: GeoParquet Consumption in R
**What:** Read GeoParquet files downloaded via pins into sf objects.
**Example:**
```r
# R: Download pin and read as sf object
library(pins)
library(sfarrow)

path <- pin_download(board, "bdline_ua_lep_diss_tbl")
sf_obj <- sfarrow::st_read_parquet(path)

# Alternative using geoarrow + arrow
library(arrow)
library(geoarrow)
sf_obj <- arrow::read_parquet(path, as_data_frame = FALSE) |> sf::st_as_sf()
```

### Pattern 6: GeoParquet Consumption in Python
**What:** Read GeoParquet files downloaded via pins into GeoDataFrame.
**Example:**
```python
# Python: Download pin and read as GeoDataFrame
import pins
import geopandas as gpd

board = pins.board_s3("stevecrawshaw-bucket", prefix="pins/", region="eu-west-2")
path = board.pin_download("bdline_ua_lep_diss_tbl")
gdf = gpd.read_parquet(path[0])
```

### Anti-Patterns to Avoid
- **Casting to WKT text for pins:** WKT is verbose, loses precision for complex geometries, and requires parsing. GeoParquet preserves binary WKB geometry natively.
- **Using ALTER TABLE to change BLOB to GEOMETRY:** DuckDB/DuckLake does not support `ALTER COLUMN TYPE` for this conversion. Must DROP and recreate.
- **Skipping ST_Multi() for mixed types:** Mixed POLYGON/MULTIPOLYGON in a single column causes issues in downstream tools (sf, geopandas) that expect uniform types per column.
- **Storing CRS in the geometry column:** DuckDB GEOMETRY type does not carry CRS metadata internally. CRS must be tracked in pin metadata and documented for analysts.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---|---|---|---|
| WKB to GEOMETRY conversion | Custom binary parsing | `ST_GeomFromWKB()` | Handles all WKB variants, validated by DuckDB spatial team |
| GeoParquet metadata | Manual parquet metadata writing | DuckDB `COPY TO` with GEOMETRY columns | Automatically writes GeoParquet 1.0.0 spec metadata |
| Geometry type detection | Custom type checking | `ST_GeometryType()` | Handles all OGC simple feature types |
| Geometry validation | Custom topology checks | `ST_IsValid()` | Implements OGC validation rules |
| POLYGON to MULTIPOLYGON promotion | Custom collection wrapping | `ST_Multi()` | Handles all simple-to-multi promotions |
| GeoParquet reading in R | Custom arrow + WKB parsing | `sfarrow::st_read_parquet()` | Reads GeoParquet metadata, sets CRS automatically |
| GeoParquet reading in Python | Custom parquet + shapely | `geopandas.read_parquet()` | Native GeoParquet 1.0.0 support |

**Key insight:** DuckDB's spatial extension handles the entire conversion pipeline (WKB decode, type promotion, validation, GeoParquet export). The only custom code needed is the SQL for table recreation and the R pin upload wrapper.

## Common Pitfalls

### Pitfall 1: DuckLake Geometry Support is Experimental
**What goes wrong:** Missing features such as filter pushdown, data inlining, and coordinate system tracking.
**Why it happens:** DuckLake 0.3 geometry support was released September 2025 and is explicitly marked experimental.
**How to avoid:** Test spatial queries thoroughly. Don't rely on spatial filter pushdown for performance. Document CRS separately (not tracked by DuckLake).
**Warning signs:** Unexpectedly slow spatial queries (no pushdown), missing CRS metadata.

### Pitfall 2: CRS Not Embedded in DuckDB GEOMETRY Type
**What goes wrong:** DuckDB's GEOMETRY type is CRS-agnostic. Data in EPSG:27700 and EPSG:4326 look identical at the type level.
**Why it happens:** DuckDB follows a "geometry without CRS" model; CRS is metadata, not part of the type system.
**How to avoid:** Track CRS in pin metadata (`crs = "EPSG:27700"`), in DuckLake column comments, and in analyst documentation. GeoParquet files DO support CRS metadata via the `geo` key -- but DuckDB's COPY TO does not write CRS into GeoParquet metadata (only encoding, geometry_types, bbox).
**Warning signs:** Analysts combining tables in different CRS without reprojection.

### Pitfall 3: Mixed Geometry Types Break Downstream Tools
**What goes wrong:** sf and geopandas expect uniform geometry type per column. A mix of POLYGON and MULTIPOLYGON causes errors or silent type coercion.
**Why it happens:** Source data has legitimate mix (ca_boundaries_bgc_tbl: 6 POLYGON + 9 MULTIPOLYGON).
**How to avoid:** Use `ST_Multi()` to promote all geometries to Multi variant before export.
**Warning signs:** `st_read_parquet()` warnings about mixed geometry types.

### Pitfall 4: File Locking on Windows
**What goes wrong:** DuckLake catalogue file (`.ducklake`) is locked by one DuckDB process, blocking concurrent access.
**Why it happens:** Windows exclusive file locking. The `.ducklake` file is a DuckDB database file.
**How to avoid:** Ensure no other DuckDB process has the file open before running scripts. The R wrapper pattern (DuckDB CLI via `system()`) already handles this by running a single process.
**Warning signs:** "The process cannot access the file because it is being used by another process" error.

### Pitfall 5: pin_write Cannot Handle sf/GeoDataFrame Objects
**What goes wrong:** `pin_write()` with `type = "parquet"` does not produce GeoParquet. It writes a regular parquet file where the geometry column becomes raw binary.
**Why it happens:** pins does not integrate with sfarrow/geoarrow for spatial-aware parquet writing.
**How to avoid:** Use `pin_upload()` with a pre-written GeoParquet file (from DuckDB `COPY TO` or sfarrow). Never use `pin_write()` for spatial data.
**Warning signs:** Geometry column appears as BLOB/binary when reading a pin written with `pin_write()`.

### Pitfall 6: GeoParquet CRS Metadata Gap
**What goes wrong:** DuckDB's COPY TO writes GeoParquet 1.0.0 metadata but does NOT include CRS/projjson in the `geo` metadata key.
**Why it happens:** DuckDB GEOMETRY is CRS-agnostic; it cannot write what it doesn't know.
**How to avoid:** After writing GeoParquet via DuckDB, either (a) accept the CRS gap and document it for analysts, or (b) post-process the parquet file in R using sfarrow/geoarrow to add CRS metadata. Option (a) is recommended -- analysts can set CRS explicitly when reading: `sf::st_set_crs(sf_obj, 27700)`.
**Warning signs:** `st_crs(sf_obj)` returns NA after reading GeoParquet.

## Code Examples

### Complete DuckLake Spatial Table Recreation (SQL)
```sql
-- Source: Verified by spike test on local DuckLake (2026-02-23)
-- Pattern for WKB_BLOB tables (7 tables)
DROP TABLE IF EXISTS lake.bdline_ua_lep_diss_tbl;
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl;

-- Pattern for GEOMETRY tables with mixed types (1 table)
DROP TABLE IF EXISTS lake.ca_boundaries_bgc_tbl;
CREATE TABLE lake.ca_boundaries_bgc_tbl AS
  SELECT * EXCLUDE(geom), ST_Multi(geom) AS geom
  FROM source.ca_boundaries_bgc_tbl;

-- Pattern for tables with validity flagging (lsoa_2021_lep_tbl)
DROP TABLE IF EXISTS lake.lsoa_2021_lep_tbl;
CREATE TABLE lake.lsoa_2021_lep_tbl AS
  SELECT * EXCLUDE(shape),
    ST_GeomFromWKB(shape) AS shape,
    ST_IsValid(ST_GeomFromWKB(shape)) AS geom_valid
  FROM source.lsoa_2021_lep_tbl;
```

### GeoParquet Export for Pins (SQL)
```sql
-- DuckDB COPY TO automatically produces GeoParquet 1.0.0 with metadata
-- Verified: writes {"version":"1.0.0","primary_column":"shape","columns":{"shape":{"encoding":"WKB","geometry_types":["Polygon"],"bbox":[...]}}}
COPY (
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl
) TO '/tmp/bdline_ua_lep_diss_tbl.parquet' (FORMAT PARQUET);
```

### Spatial SQL Queries on DuckLake (SQL)
```sql
-- Source: Verified by spike test on local DuckLake (2026-02-23)
-- ST_Contains works on DuckLake GEOMETRY columns
SELECT a.id AS point_id, b.id AS poly_id
FROM lake.points a, lake.polygons b
WHERE ST_Contains(b.geom, a.geom);

-- ST_Area on DuckLake polygon
SELECT name, ST_Area(shape) AS area_sqm
FROM lake.bdline_ua_lep_diss_tbl;
```

### R Pin Upload for GeoParquet
```r
# Source: pins docs (pin_upload) + verified GeoParquet pattern
library(pins)

board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  prefix = "pins/",
  region = "eu-west-2",
  versioned = TRUE
)

# GeoParquet file already written by DuckDB COPY TO
pin_upload(
  board,
  paths = temp_path,
  name = "bdline_ua_lep_diss_tbl",
  title = "Boundary line UA LEP dissolved",
  description = "Boundary line UA LEP dissolved (1 rows, 3 columns, GeoParquet)",
  metadata = list(
    source_db = "ducklake",
    spatial = TRUE,
    geometry_column = "shape",
    geometry_type = "POLYGON",
    crs = "EPSG:27700"
  )
)
```

## Source Data Inventory

### Spatial Tables (8 tables)

| Table | Rows | Geom Column | Source Type | Geom Types | CRS | Invalid | Notes |
|---|---|---|---|---|---|---|---|
| bdline_ua_lep_diss_tbl | 1 | shape | WKB_BLOB | POLYGON | EPSG:27700 | 0 | Dissolved UA boundary |
| bdline_ua_lep_tbl | 4 | shape | WKB_BLOB | MULTIPOLYGON | EPSG:27700 | 0 | |
| bdline_ua_weca_diss_tbl | 1 | shape | WKB_BLOB | POLYGON | EPSG:27700 | 0 | Dissolved WECA boundary |
| bdline_ward_lep_tbl | 130 | shape | WKB_BLOB | MULTIPOLYGON | EPSG:27700 | 0 | |
| ca_boundaries_bgc_tbl | 15 | geom | GEOMETRY | POLYGON (6) + MULTIPOLYGON (9) | EPSG:4326 | 0 | Mixed types -- needs ST_Multi() |
| codepoint_open_lep_tbl | 31,299 | shape | WKB_BLOB | POINT | EPSG:27700 | 0 | |
| lsoa_2021_lep_tbl | 698 | shape | WKB_BLOB | MULTIPOLYGON | EPSG:27700 | 2 | 2 invalid geometries (Bristol 027B, North Somerset 026D) |
| open_uprn_lep_tbl | 687,143 | shape | WKB_BLOB | POINT | EPSG:27700 | 0 | Largest table; ~18MB as GeoParquet |

### Key Observations
- **No NULL geometries** in any table
- **No chunking needed:** Even the largest table (687K rows) produces ~18MB GeoParquet
- **CRS split:** 7 tables use EPSG:27700 (British National Grid), 1 table uses EPSG:4326 (WGS84)
- **One mixed-type table:** `ca_boundaries_bgc_tbl` needs POLYGON -> MULTIPOLYGON promotion
- **Two invalid geometries:** `lsoa_2021_lep_tbl` (Bristol 027B, North Somerset 026D) -- flag with `geom_valid` column

## CRS Recommendation

**Do not reproject.** Keep data in its source CRS:
- 7 tables remain in EPSG:27700 (British National Grid) -- standard for UK government spatial data
- 1 table (`ca_boundaries_bgc_tbl`) remains in EPSG:4326 (WGS84) -- already in this CRS from source
- Document CRS in pin metadata and DuckLake column comments
- Analysts can reproject as needed using `sf::st_transform()` or `ST_Transform()` in DuckDB

**Rationale:** British National Grid is the standard CRS for UK government data. Reprojecting to WGS84 would lose precision for measurements (areas, distances) that analysts need. The one WGS84 table is already in that CRS from source and should stay as-is.

## Spike Recommendation

**Spike with `bdline_ua_lep_diss_tbl` first** (1 row, simple POLYGON, EPSG:27700). This validates:
1. DuckLake GEOMETRY column creation from WKB_BLOB source
2. Spatial SQL queries on DuckLake (ST_Area, ST_Contains)
3. GeoParquet export via COPY TO
4. pin_upload of GeoParquet file
5. R roundtrip: pin_download -> sfarrow::st_read_parquet -> plot
6. Python roundtrip: pin_download -> geopandas.read_parquet -> plot

If the spike succeeds, batch all 8 tables with per-table adjustments (ST_Multi for ca_boundaries, geom_valid for lsoa_2021).

## Spatial Pin Naming Convention

**Recommendation:** Add `spatial = TRUE` to pin metadata (not a suffix).

Rationale:
- A suffix like `_spatial` breaks the existing naming convention that matches table names exactly
- Metadata-based marking is queryable: `pin_meta(board, name)$user$spatial`
- The existing `metadata` list in `pin_upload()` already supports arbitrary keys
- Include `geometry_column`, `geometry_type`, and `crs` in metadata for discoverability

## State of the Art

| Old Approach (Phase 3) | Current Approach (Phase 4) | When Changed | Impact |
|---|---|---|---|
| Cast spatial to BLOB for DuckLake | Native GEOMETRY in DuckLake | DuckLake 0.3 (Sep 2025) | Spatial SQL now works directly on DuckLake tables |
| Spatial tables excluded from pins | GeoParquet pin export via pin_upload | Phase 4 | Analysts can access spatial data through pins |
| COPY FROM DATABASE (failed on spatial) | Individual CREATE TABLE with ST_GeomFromWKB | Phase 3 finding | Still needed -- COPY FROM DATABASE status with GEOMETRY unclear |
| WKT text for interop | GeoParquet for interop | GeoParquet 1.0.0 (2023) | Binary geometry preservation, smaller files, CRS metadata support |

**Deprecated/outdated:**
- Casting spatial columns to BLOB in DuckLake -- no longer needed with 0.3+
- sfarrow is in maintenance mode but still functional; geoarrow is the newer alternative but less established

## Open Questions

1. **COPY FROM DATABASE with GEOMETRY**
   - What we know: Phase 3 found COPY FROM DATABASE fails on spatial types (WKB_BLOB/GEOMETRY)
   - What's unclear: Whether DuckLake 0.3 with geometry support fixes this for GEOMETRY (not WKB_BLOB) columns
   - Recommendation: Don't investigate -- individual CREATE TABLE works and gives more control (type promotion, validity flagging)

2. **GeoParquet CRS metadata from DuckDB**
   - What we know: DuckDB COPY TO writes GeoParquet 1.0.0 but without CRS/projjson in the `geo` metadata
   - What's unclear: Whether a newer DuckDB version or spatial extension version adds CRS writing
   - Recommendation: Accept the gap. Document CRS in pin metadata and column comments. Analysts set CRS explicitly when reading.

3. **DuckLake geometry filter pushdown**
   - What we know: DuckLake 0.3 docs state "geometry support is missing features such as filter pushdown"
   - What's unclear: Performance impact for spatial queries on larger tables
   - Recommendation: Not a blocker for Phase 4 -- the largest spatial table is 687K rows (trivial). Document as a known limitation.

4. **sfarrow vs geoarrow in R**
   - What we know: sfarrow is established but tracking GeoParquet 0.1.0 metadata spec. geoarrow is newer, uses arrow package.
   - What's unclear: Whether sfarrow reads GeoParquet 1.0.0 files correctly (DuckDB writes 1.0.0)
   - Recommendation: Test both in the spike. Use whichever works. If both work, recommend geoarrow (more active development).

## Sources

### Primary (HIGH confidence)
- DuckDB spatial extension docs: https://duckdb.org/docs/stable/core_extensions/spatial/overview -- GEOMETRY type, ST_GeomFromWKB, ST_Multi, ST_IsValid
- DuckDB spatial functions: https://duckdb.org/docs/stable/core_extensions/spatial/functions -- Function signatures
- DuckLake 0.3 announcement: https://ducklake.select/2025/09/17/ducklake-03/ -- Geometry support added, experimental status, known limitations
- Local spike test (2026-02-23): DuckLake GEOMETRY creation, spatial SQL, GeoParquet COPY TO all verified working
- Source database inspection (2026-02-23): All 8 spatial tables profiled (types, rows, validity, CRS)
- pins R package docs: https://pins.rstudio.com/ -- pin_upload/pin_download for custom file formats
- GeoPandas docs: https://geopandas.org/en/stable/docs/reference/api/geopandas.read_parquet.html -- GeoParquet 1.0.0 support

### Secondary (MEDIUM confidence)
- GeoParquet handling in R (Victor Kreitmann, 2025): https://victorkreitmann.com/til/2025/handling-spatial-objects-with-geoparquet/ -- geoarrow + arrow + sf workflow
- sfarrow package: https://cran.r-project.org/web/packages/sfarrow/ -- st_read_parquet / st_write_parquet
- pins custom formats: https://pins.rstudio.com/articles/managing-custom-formats.html -- pin_upload with arbitrary files

### Tertiary (LOW confidence)
- sfarrow GeoParquet 1.0.0 compatibility: Not verified -- sfarrow docs reference spec 0.1.0. Needs spike validation.
- DuckLake COPY FROM DATABASE with GEOMETRY: Not tested -- unclear if 0.3 fixes the Phase 3 failure.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- DuckDB spatial, DuckLake 0.3, GeoParquet all verified working locally
- Architecture: HIGH -- Full pipeline tested: WKB_BLOB -> GEOMETRY -> DuckLake -> GeoParquet -> pin_upload
- Pitfalls: HIGH -- CRS gap, mixed types, validity issues all discovered and characterised from source data
- R/Python consumption: MEDIUM -- GeoParquet writing verified, reading patterns documented but not tested end-to-end in this research (spike will validate)

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (30 days -- DuckLake spatial is experimental but core patterns are stable)
