# Architecture Research

**Domain:** DuckDB-to-S3 data sharing platform (DuckLake + pins)
**Researched:** 2026-02-22
**Confidence:** HIGH (based on official DuckLake docs v0.3, project files, pins R code)

## System Overview

```
 LOCAL ENVIRONMENT                          AWS S3 (eu-west-2)
+---------------------------+              +------------------------------------------+
|                           |              |  s3://stevecrawshaw-bucket/              |
|  data/mca_env_base.duckdb |              |                                          |
|  (18 tables, comments,   |              |  ducklake/                               |
|   WKB_BLOB spatial cols)  |              |  +-- metadata.ducklake  (catalog DB)     |
|                           |              |  +-- metadata.ducklake.files/            |
+----------+----------------+              |      +-- main/                           |
           |                               |          +-- table_a/                    |
           | Export Pipeline               |          |   +-- ducklake-<uuid>.parquet |
           | (Python, DuckDB)              |          +-- table_b/                    |
           |                               |              +-- ducklake-<uuid>.parquet |
           v                               |                                          |
+---------------------------+              |  pins/                                   |
|  Export Script             |              |  +-- table_a/                            |
|  1. Read source tables    |              |  |   +-- <timestamp>/                    |
|  2. Extract metadata      |              |  |       +-- table_a.parquet             |
|  3. Convert WKB->geometry |              |  |       +-- data.txt (pin manifest)     |
|  4. Write to DuckLake     |  -------->   |  +-- table_b/                            |
|  5. Apply COMMENT ON      |              |      +-- <timestamp>/                    |
|  6. Write pins board      |              |          +-- table_b.parquet             |
+---------------------------+              |          +-- data.txt                    |
                                           +------------------------------------------+
                                                        |              |
                                           +------------+    +---------+---------+
                                           |                 |                   |
                                     DuckLake Clients    pins (R)          pins (Python)
                                     (DuckDB anywhere)   pin_read()        pins.board_s3()
                                     ATTACH 'ducklake:   board_s3()
                                       s3://...'
```

## Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|----------------|-------------------|
| **Source DuckDB** | Holds authoritative data with table/column comments and spatial geometry | Export Pipeline (read-only) |
| **Export Pipeline** | Reads source, transforms spatial data, writes to DuckLake and pins on S3 | Source DuckDB, S3 (DuckLake + pins) |
| **DuckLake Catalogue** | Stores metadata (schema, columns, tags, file stats) in a DuckDB file on S3 | S3 data files, DuckLake clients |
| **DuckLake Data Files** | Parquet files on S3 holding actual table data | DuckLake Catalogue (referenced by), DuckLake clients (read) |
| **pins Board** | Independent S3 board providing simple pin_read() access for R/Python users | S3 (storage), R/Python consumers |
| **S3 Bucket** | Object storage backend for both DuckLake and pins | All components |

## Recommended Architecture

### Two Parallel Access Paths

The system provides two independent ways to access the same data on S3, serving different user populations:

1. **DuckLake path** -- for analysts who use DuckDB and want full SQL, time travel, and schema evolution. They `ATTACH 'ducklake:s3://...'` and query tables directly.

2. **pins path** -- for R/Python users who want simple `pin_read("table_name")` access without needing to understand DuckDB or lake formats. Pins manages versioning, metadata display, and simple data frames.

Both paths read from parquet files on the same S3 bucket but are managed independently. DuckLake files live under `ducklake/` and pins files live under `pins/`. They are not the same parquet files -- this is deliberate. DuckLake manages its own file lifecycle (compaction, snapshots, deletions) which would break pins if they shared files.

### Why Separate File Sets, Not Shared

DuckLake's file management is incompatible with pins' expectations:

- DuckLake may compact, merge, or delete files as part of maintenance
- DuckLake uses `field_id` in Parquet metadata for schema evolution, which pins does not understand
- pins expects stable, versioned snapshots at predictable paths
- DuckLake path prefixes follow `main/<table_name>/ducklake-<uuid>.parquet` conventions controlled by the catalogue

The cost of duplication is minimal (parquet is compressed, data is not enormous for 18 tables) and the operational simplicity is significant.

## Data Flow

### Primary Export Flow

```
Source DuckDB (mca_env_base.duckdb)
    |
    | [1] Read table list + schema
    | [2] Extract table comments (duckdb_tables().comment)
    | [3] Extract column comments (duckdb_columns().comment)
    |
    v
Export Pipeline (Python)
    |
    |--- [4a] DuckLake Branch --->  ATTACH 'ducklake:metadata.ducklake'
    |       |                          (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/')
    |       |-- CREATE TABLE AS SELECT ... FROM source
    |       |-- COMMENT ON TABLE ... IS '...'
    |       |-- COMMENT ON COLUMN ... IS '...'
    |       |-- (Spatial: geometry columns handled natively by DuckLake)
    |       +-- COMMIT (creates snapshot)
    |
    |--- [4b] pins Branch -------> pins.board_s3("stevecrawshaw-bucket", prefix="pins/")
            |-- For each table:
            |     Convert WKB_BLOB to WKT string (pins cannot handle WKB)
            |     pin_write(df, name="table_name", type="parquet",
            |               title="Table comment", description="...")
            +-- Pin metadata includes column descriptions
```

### Refresh Flow (Periodic Updates)

```
Source DuckDB (updated)
    |
    v
Export Pipeline
    |
    |--- DuckLake: Use MERGE INTO or DROP + CREATE TABLE AS
    |     (DuckLake creates new snapshot automatically)
    |     Previous data accessible via time travel
    |
    |--- pins: pin_write() creates new version automatically
          Previous versions accessible via pin_versions()
```

### Consumer Read Flow

```
DuckLake Consumer (any DuckDB client):
    INSTALL ducklake;
    CREATE SECRET (TYPE s3, KEY_ID '...', SECRET '...', REGION 'eu-west-2');
    ATTACH 'ducklake:s3://stevecrawshaw-bucket/ducklake/metadata.ducklake' AS env_data;
    USE env_data;
    SELECT * FROM air_quality_data WHERE year > 2020;
    -- Time travel: SELECT * FROM table AT (VERSION => 3);

pins Consumer (R):
    board <- board_s3(bucket = "stevecrawshaw-bucket",
                      prefix = "pins/",
                      region = "eu-west-2")
    df <- pin_read(board, "air_quality_data")

pins Consumer (Python):
    from pins import board_s3
    board = board_s3("stevecrawshaw-bucket", prefix="pins/",
                     region="eu-west-2")
    df = board.pin_read("air_quality_data")
```

## Metadata Flow

### How Comments Survive the Journey

This is a critical architectural concern. The source DuckDB has both table-level and column-level comments. These must be preserved through to consumers.

**DuckLake path:**

DuckLake stores comments as tags in `ducklake_tag` (table-level) and `ducklake_column_tag` (column-level) tables. The `COMMENT ON` syntax is natively supported (confirmed in DuckLake docs, section "Comments"):

```sql
-- After creating table in DuckLake:
COMMENT ON TABLE my_table IS 'Description from source';
COMMENT ON COLUMN my_table.col1 IS 'Column description from source';
```

These are stored with snapshot versioning, so they survive schema evolution. DuckLake consumers can read them via standard DuckDB metadata functions. **Confidence: HIGH** -- this is explicitly documented in the DuckLake docs.

**pins path:**

pins stores metadata differently. The `pin_write()` function accepts `title` and `description` parameters, plus arbitrary metadata. Column-level comments must be stored as custom metadata:

```python
# Python pins
board.pin_write(
    df,
    name="table_name",
    type="parquet",
    title="Table-level comment from source",
    metadata={"column_descriptions": {"col1": "desc1", "col2": "desc2"}}
)
```

```r
# R pins
board %>% pin_write(
    df,
    name = "table_name",
    type = "parquet",
    title = "Table-level comment from source",
    metadata = list(column_descriptions = list(col1 = "desc1", col2 = "desc2"))
)
```

**Confidence: MEDIUM** -- pins title/description is well-documented; custom metadata for column descriptions needs validation during implementation.

### Metadata Extraction Script Pattern

```python
import duckdb

def extract_metadata(con: duckdb.DuckDBPyConnection, table_name: str) -> dict:
    """Extract table and column comments from source DuckDB."""
    table_comment = con.execute(
        "SELECT comment FROM duckdb_tables() WHERE table_name = ?",
        [table_name]
    ).fetchone()[0]

    columns = con.execute(
        "SELECT column_name, comment FROM duckdb_columns() WHERE table_name = ?",
        [table_name]
    ).fetchall()

    return {
        "table_comment": table_comment,
        "column_comments": {name: comment for name, comment in columns if comment}
    }
```

## Spatial Data Handling

### The WKB_BLOB Challenge

Some source tables contain `WKB_BLOB` columns (Well-Known Binary geometry). These need different handling for each access path:

**DuckLake path:**

DuckLake v0.3 natively supports geometry types in Parquet files (confirmed in docs, "Geometry Types" section). The `geometry` type supports point, linestring, polygon, multipoint, multilinestring, multipolygon, and geometrycollection.

The recommended approach:
1. Load the DuckDB `spatial` extension
2. Convert WKB_BLOB to GEOMETRY type during export: `ST_GeomFromWKB(wkb_column)`
3. DuckLake will store this as native Parquet geometry type
4. DuckLake consumers with the `spatial` extension can query geometry natively

**Confidence: MEDIUM** -- DuckLake docs confirm geometry type support, but the exact WKB-to-DuckLake-geometry conversion path needs validation. It is possible the `spatial` extension is required for both writing and reading.

**pins path:**

pins (and most R/Python data frame consumers) cannot handle binary geometry columns. Options:

1. **Convert to WKT (Well-Known Text)** -- human-readable, larger, but universally compatible
2. **Drop geometry columns** -- simplest, if geometry not needed by pins consumers
3. **Store geometry as separate GeoParquet files** -- more complex, better for GIS users

**Recommendation:** Convert to WKT for pins. Most R users can then use `sf::st_as_sf(df, wkt = "geometry_wkt")` to reconstruct geometry. Python users can use `shapely.from_wkt()`.

```python
# During pins export:
df["geometry_wkt"] = df["WKB_BLOB"].apply(lambda x: convert_wkb_to_wkt(x))
df = df.drop(columns=["WKB_BLOB"])
```

## S3 Bucket Layout

### Recommended Structure

```
s3://stevecrawshaw-bucket/
+-- ducklake/
|   +-- metadata.ducklake              # DuckLake catalog DB (DuckDB file)
|   +-- metadata.ducklake.files/       # Auto-managed by DuckLake
|       +-- main/                      # Default schema
|           +-- air_quality_data/      # One folder per table
|           |   +-- ducklake-<uuid>.parquet
|           +-- flood_risk_zones/
|           |   +-- ducklake-<uuid>.parquet
|           +-- ... (18 tables)
|
+-- pins/
    +-- air_quality_data/              # One folder per pin
    |   +-- 20260222T120000Z/          # Timestamped version
    |       +-- air_quality_data.parquet
    |       +-- data.txt               # Pin manifest/metadata
    +-- flood_risk_zones/
    |   +-- 20260222T120000Z/
    |       +-- flood_risk_zones.parquet
    |       +-- data.txt
    +-- ... (18 tables)
```

### Layout Rationale

- **Separate `ducklake/` and `pins/` prefixes** prevent file management conflicts
- **DuckLake manages its own path structure** under `metadata.ducklake.files/` -- do not manually organise files here
- **pins uses its own versioning** with timestamped directories -- this is automatic
- **No shared parquet files** between the two systems (see rationale above)

### DuckLake Catalogue Database Location

The DuckLake catalogue database (`metadata.ducklake`) is itself stored on S3. This works because:

- DuckDB can read/write files on S3 via the `httpfs` extension
- For single-writer scenarios (which this is -- periodic batch export), DuckDB-as-catalogue is sufficient
- Multi-user read access works fine; only writes are single-client

If multi-user write access is ever needed, migrate the catalogue to PostgreSQL while keeping data files on S3:

```sql
-- Future: PostgreSQL catalog with S3 data
ATTACH 'ducklake:postgres:dbname=ducklake_catalog host=...'
    (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');
```

**For now, DuckDB file catalogue on S3 is the right choice** -- simplest setup, no infrastructure to manage, sufficient for single-writer periodic refresh.

## Recommended Project Structure

```
ducklake/
+-- main.py                    # Entry point / CLI
+-- src/
|   +-- __init__.py
|   +-- config.py              # S3 bucket, region, paths, credentials config
|   +-- source.py              # Read source DuckDB, extract metadata
|   +-- export_ducklake.py     # DuckLake export: create tables, apply comments
|   +-- export_pins.py         # pins export: write pins with metadata
|   +-- spatial.py             # WKB/geometry conversion utilities
|   +-- refresh.py             # Orchestrate periodic refresh (diff detection)
+-- data/
|   +-- mca_env_base.duckdb    # Source database (gitignored)
+-- docs/
|   +-- ducklake-docs.md       # DuckLake reference
+-- tests/
|   +-- test_source.py         # Test metadata extraction
|   +-- test_export.py         # Test export logic
|   +-- test_spatial.py        # Test geometry conversion
+-- .planning/                 # GSD planning files
+-- pyproject.toml
+-- uv.lock
```

### Structure Rationale

- **`src/source.py`:** Isolates all interaction with the source DuckDB. Single responsibility: read tables, extract comments, detect spatial columns.
- **`src/export_ducklake.py`:** Owns the DuckLake ATTACH, CREATE TABLE, COMMENT ON flow. Separate from pins because the two exports are independent.
- **`src/export_pins.py`:** Owns the pins board_s3 setup and pin_write calls. Handles WKT conversion for spatial columns.
- **`src/spatial.py`:** Geometry conversion logic (WKB to geometry for DuckLake, WKB to WKT for pins). Isolated because it is the most likely source of bugs.
- **`src/config.py`:** Centralised configuration. Avoids scattering S3 bucket names across modules.

## Architectural Patterns

### Pattern 1: Extract-Transform-Load with Dual Sinks

**What:** Single read from source, two independent write paths (DuckLake + pins)
**When to use:** When the same data must be accessible through different interfaces with different requirements
**Trade-offs:** Duplicates storage (minor cost) but decouples the two access paths completely. Either can be disabled, modified, or replaced independently.

```python
def export_all(source_path: Path, config: Config) -> None:
    """Read once, write twice."""
    source_con = duckdb.connect(str(source_path), read_only=True)
    tables = get_table_list(source_con)
    metadata = {t: extract_metadata(source_con, t) for t in tables}

    # Sink 1: DuckLake
    export_to_ducklake(source_con, tables, metadata, config)

    # Sink 2: pins
    export_to_pins(source_con, tables, metadata, config)

    source_con.close()
```

### Pattern 2: DuckLake COPY FROM DATABASE for Bulk Migration

**What:** Use DuckDB's `COPY FROM DATABASE` for initial bulk load, then apply metadata separately
**When to use:** First-time setup when all 18 tables need creating
**Trade-offs:** Very fast bulk copy but does not transfer comments (comments are DuckDB-specific, not part of the data). Must apply `COMMENT ON` statements afterwards.

```sql
-- Bulk copy all tables from source to DuckLake
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);
ATTACH 'ducklake:s3://stevecrawshaw-bucket/ducklake/metadata.ducklake' AS lake
    (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

COPY FROM DATABASE source TO lake;

-- Then apply comments (must be done per-table, per-column)
COMMENT ON TABLE lake.main.air_quality IS 'Air quality measurements...';
COMMENT ON COLUMN lake.main.air_quality.pm25 IS 'PM2.5 concentration in ug/m3';
```

**Confidence: MEDIUM** -- `COPY FROM DATABASE` is documented for DuckDB-to-DuckLake migration. Whether it handles `WKB_BLOB` columns correctly (converting to geometry type) needs validation. May need per-table `CREATE TABLE AS SELECT ST_GeomFromWKB(...)` for spatial tables instead.

### Pattern 3: Idempotent Refresh with Snapshot Versioning

**What:** On periodic refresh, drop and recreate tables in DuckLake rather than attempting incremental updates
**When to use:** When the source data is a complete refresh (not incremental changes)
**Trade-offs:** Simpler code (no diff logic), uses more storage temporarily (old snapshots retained until expired), but DuckLake handles cleanup via `CHECKPOINT`.

```python
def refresh_ducklake(source_con, config):
    """Full refresh: drop and recreate all tables."""
    lake_con = duckdb.connect()
    lake_con.execute(f"ATTACH 'ducklake:{config.ducklake_metadata}' AS lake")
    lake_con.execute("USE lake")

    for table in tables:
        lake_con.execute(f"DROP TABLE IF EXISTS {table}")
        lake_con.execute(f"CREATE TABLE {table} AS SELECT * FROM source.{table}")
        # Re-apply comments...

    # Old data still accessible via time travel until expired
    lake_con.execute("CHECKPOINT")
```

## Anti-Patterns

### Anti-Pattern 1: Sharing Parquet Files Between DuckLake and pins

**What people do:** Write parquet to S3 once, register in DuckLake via `ducklake_add_data_files`, and point pins at the same files.
**Why it's wrong:** DuckLake takes ownership of registered files and may delete them during compaction. pins expects stable file paths. One system's maintenance will break the other.
**Do this instead:** Write separate parquet files for each system. The storage cost is negligible compared to the operational headache.

### Anti-Pattern 2: Storing the DuckLake Catalogue Locally While Data is on S3

**What people do:** Keep `metadata.ducklake` as a local file, with `DATA_PATH` pointing to S3.
**Why it's wrong:** Only the machine with the local catalogue file can query DuckLake. Other team members cannot access it. The catalogue must be co-located with or accessible alongside the data.
**Do this instead:** Store the catalogue on S3 (for single-writer) or PostgreSQL (for multi-writer). For this project, S3 is sufficient.

### Anti-Pattern 3: Manual Parquet File Organisation in DuckLake's Data Path

**What people do:** Pre-organise parquet files into a folder structure, then try to register them with DuckLake.
**Why it's wrong:** DuckLake manages its own path structure (`main/<table_name>/ducklake-<uuid>.parquet`). Manually placed files need `ducklake_add_data_files` with careful column mapping and lose schema evolution benefits.
**Do this instead:** Let DuckLake manage file layout. Use `CREATE TABLE AS SELECT` or `INSERT INTO` and DuckLake will write parquet files in its own structure.

### Anti-Pattern 4: Trying to Preserve WKB_BLOB as-is in Parquet for pins

**What people do:** Export WKB_BLOB columns directly to parquet and expect R/Python to handle them.
**Why it's wrong:** Most R and Python parquet readers will treat WKB as raw binary, which is not useful without explicit conversion. pins consumers expect readable data frames.
**Do this instead:** Convert to WKT for pins (human-readable, easy to convert back to sf/shapely). For DuckLake, convert to native geometry type via `ST_GeomFromWKB()`.

## Integration Points

### External Services

| Service | Integration Pattern | Notes |
|---------|---------------------|-------|
| **AWS S3** | DuckDB httpfs extension + boto3 for pins | Both systems need AWS credentials. Use `~/.aws/credentials` or environment variables. DuckDB uses `CREATE SECRET (TYPE s3, ...)` |
| **Source DuckDB** | Direct file read (read_only=True) | No network -- local file. Must not be opened for write by another process simultaneously |

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Source -> Export Pipeline | DuckDB Python API (`duckdb.connect()`) | Read-only connection to source |
| Export Pipeline -> DuckLake | DuckDB SQL via `ATTACH 'ducklake:...'` | Write path; needs S3 write credentials |
| Export Pipeline -> pins | Python `pins` library API | Independent of DuckDB; reads pandas/polars DataFrames |
| DuckLake -> Consumers | DuckDB `ATTACH` from any client | Read-only; needs S3 read credentials |
| pins -> Consumers | `pin_read()` from R or Python | Read-only; needs S3 read credentials |

## Build Order (Dependency Chain)

The following build order reflects dependencies -- each phase requires the previous one:

### Phase 1: Foundation -- Source Reading and Metadata Extraction

- Read source DuckDB, enumerate tables
- Extract table-level and column-level comments
- Identify spatial columns (WKB_BLOB types)
- Produce a metadata dictionary per table
- **No S3 needed yet.** Can be tested entirely locally.

### Phase 2: DuckLake Export (non-spatial tables first)

- Set up S3 credentials and DuckDB httpfs
- Create DuckLake catalogue on S3 with `ATTACH 'ducklake:...'`
- Export non-spatial tables via `CREATE TABLE AS SELECT`
- Apply `COMMENT ON` for table and column metadata
- Verify: connect from a separate DuckDB session, query data, check comments
- **Depends on:** Phase 1 (metadata extraction)

### Phase 3: pins Export (non-spatial tables first)

- Set up pins S3 board (`board_s3`)
- Write each non-spatial table as a pin with metadata
- Verify: `pin_read()` from both R and Python
- **Depends on:** Phase 1 (metadata extraction). Independent of Phase 2 (can run in parallel).

### Phase 4: Spatial Data Handling

- Install DuckDB `spatial` extension
- Convert WKB_BLOB to GEOMETRY for DuckLake export
- Convert WKB_BLOB to WKT for pins export
- Verify geometry roundtrip: source WKB -> DuckLake geometry -> consumer spatial query
- Verify WKT in pins: pin_read() -> sf::st_as_sf() in R
- **Depends on:** Phases 2 and 3 (basic export working). This is the riskiest phase.

### Phase 5: Refresh Pipeline

- Build idempotent refresh script (full re-export)
- Handle DuckLake snapshot management (drop + recreate, or MERGE INTO)
- Handle pins versioning (pin_write overwrites)
- Add DuckLake CHECKPOINT for maintenance
- **Depends on:** Phases 2, 3, 4 (all export paths working)

### Phase 6: Documentation and Consumer Guide

- Document how to connect to DuckLake from DuckDB
- Document how to use pins from R and Python
- Document spatial data access patterns
- Document refresh schedule and process

## Scaling Considerations

| Scale | Architecture Adjustments |
|-------|--------------------------|
| Current (18 tables, ~team of 10) | DuckDB catalogue on S3, single-writer export script. Sufficient. |
| 50+ tables, 10+ concurrent readers | Still fine with current architecture. S3 handles read concurrency well. |
| Multiple writers needed | Migrate DuckLake catalogue from DuckDB to PostgreSQL. Data stays on S3. Code change is one line in ATTACH statement. |
| Very large tables (>1GB per table) | Consider partitioning in DuckLake (`ALTER TABLE SET PARTITIONED BY`). Consider chunked pins writes. |

### Scaling Priorities

1. **First bottleneck:** Export script runtime for large tables. Mitigate with `per_thread_output` DuckLake option and zstd compression.
2. **Second bottleneck:** S3 costs if data refreshes are very frequent. Mitigate with DuckLake snapshot expiry (`expire_older_than`) and pins version pruning.

## Key Decisions Summary

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Catalogue backend | DuckDB file on S3 | Simplest; sufficient for single-writer; movable to PostgreSQL later |
| S3 layout | Separate `ducklake/` and `pins/` prefixes | Prevents file management conflicts between systems |
| Parquet sharing | No sharing between DuckLake and pins | DuckLake file lifecycle would break pins |
| Spatial handling (DuckLake) | Convert WKB to native geometry via spatial extension | DuckLake v0.3 supports geometry types natively |
| Spatial handling (pins) | Convert WKB to WKT string | Universal compatibility with R sf and Python shapely |
| Refresh strategy | Full drop + recreate | Simpler than incremental; DuckLake time travel preserves history |
| Parquet compression | zstd | Best compression ratio for analytical data; supported by DuckLake |
| Metadata preservation | COMMENT ON for DuckLake; title + custom metadata for pins | Native DuckLake support; pins custom metadata for column descriptions |

## Sources

- DuckLake v0.3 specification and DuckDB extension documentation: `docs/ducklake-docs.md` (local copy, HIGH confidence)
- DuckLake comments feature: Section "Comments" in docs, confirming `COMMENT ON TABLE` and `COMMENT ON COLUMN` support
- DuckLake geometry support: Section "Geometry Types" in specification, confirming native geometry type support
- DuckLake S3 storage: Section "Choosing Storage" confirming AWS S3 via httpfs extension
- DuckLake path structure: Section "Paths" documenting `main/<table>/<file>.parquet` layout
- DuckLake migration: Section "DuckDB to DuckLake" documenting `COPY FROM DATABASE`
- pins R usage: `aws_setup.r` in project (working example of board_s3 + pin_write)
- pins Python: `pyproject.toml` confirming `pins>=0.9.1` dependency
- Project README: Confirms goals (upload to S3, pins access, DuckLake catalogue)

---
*Architecture research for: DuckDB-to-S3 data sharing (DuckLake + pins)*
*Researched: 2026-02-22*
