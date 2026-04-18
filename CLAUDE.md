# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A data platform for the West of England Combined Authority (WECA). It maintains 18 curated datasets accessible via two routes:

- **DuckLake** — SQL catalogue (`data/mca_env.ducklake`) backed by Parquet files on S3. Analysts query with DuckDB CLI.
- **Pins** — the same data pinned to S3 as Parquet/GeoParquet, readable from R (`pins`) or Python (`pins`).

The source of truth is a separate DuckDB database: `~/projects/data-lake/data_lake/mca_env_base.duckdb`. This project does not own that database; it reads from it.

## DuckDB version

Minimum DuckDB CLI: **1.5.2**. `AUTOMATIC_MIGRATION` is off by default in DuckLake 1.0 — run `scripts/migrate_ducklake.R` once to upgrade an existing 0.x catalogue. `GEOMETRY` is now a DuckDB core built-in type; the spatial extension is still needed for `ST_*` functions.

## Key constraint: DuckDB CLI vs R package

The R `duckdb` package (v1.4.4) **cannot load the `ducklake` extension**. Any operation against `data/mca_env.ducklake` must use the DuckDB CLI via `system()`. This pattern is used throughout the R scripts. Never try to open the `.ducklake` file via `dbConnect(duckdb(), ...)` in R.

## Running the pipeline

All scripts are run from the **project root**.

```bash
# Full refresh: re-exports all 18 tables to DuckLake + S3 pins, then generates catalogues
Rscript scripts/refresh.R

# One-time catalogue creation (only needed when starting from scratch)
Rscript scripts/create_ducklake.R

# Apply column/table comments and create views (run after create_ducklake.R)
Rscript scripts/apply_comments.R

# Validate all S3 pins from Python
uv run python scripts/validate_pins.py

# List available pins / read one from Python
uv run python main.py
```

## Python environment

```bash
uv sync          # install dependencies
uv run python scripts/validate_pins.py
uv run python main.py
```

Python 3.13. Key dependencies: `duckdb`, `pins[aws]`, `pyarrow`, `geopandas`, `boto3`.

## Docs (Quarto)

```bash
quarto render docs   # render locally
quarto preview docs  # live preview
```

Docs auto-deploy to GitHub Pages on push to `main` when files under `docs/` change.

## Architecture

### Data flow

```
mca_env_base.duckdb (source, read-only)
       │
       ├─► DuckLake CLI export ──► data/mca_env.ducklake (metadata)
       │                            + s3://stevecrawshaw-bucket/ducklake/data/ (Parquet)
       │
       └─► Pins export ──────────► s3://stevecrawshaw-bucket/pins/ (Parquet / GeoParquet)
```

`refresh.R` is the single entry point for both destinations. It runs in six steps: pre-flight → DuckLake DROP+CREATE → row count validation → pin export → `datasets_catalogue` → `columns_catalogue`.

### Table classification

Spatial tables are detected by BLOB/GEOMETRY/WKB column types. Eight spatial tables use GeoParquet export (via DuckDB CLI + spatial extension). Ten non-spatial tables use `pin_write` or chunked `pin_upload` (threshold: 5 M rows).

### Edge cases baked into the scripts

| Table | Special handling |
|-------|-----------------|
| `ca_boundaries_bgc_tbl` | Mixed POLYGON/MULTIPOLYGON → `ST_Multi()` promotes all to MULTIPOLYGON |
| `lsoa_2021_lep_tbl` | Invalid geometries → adds `geom_valid` BOOLEAN column |
| Tables > 5 M rows | Chunked export (3 M rows/chunk) via `pin_upload` |

### Self-describing catalogue

`refresh.R` generates two catalogue tables written to both DuckLake and S3 pins:
- `datasets_catalogue` — one row per table/view with row counts, spatial metadata, bounding boxes
- `columns_catalogue` — one row per column with data type, description, and up to 3 example values

### Views

12 views defined in `scripts/create_views.sql`: 4 non-spatial source views (including WECA-filtered joins) and 8 `*_weca_vw` views that filter each base table to the four WECA local authorities.

## AWS / S3

- Region: `eu-west-2` (London)
- Bucket: `stevecrawshaw-bucket`
- DuckLake data: `s3://stevecrawshaw-bucket/ducklake/data/`
- Pins: `s3://stevecrawshaw-bucket/pins/`
- Auth: credential chain (`~/.aws/credentials`)

DuckDB CLI sessions always need:
```sql
INSTALL ducklake; LOAD ducklake;
INSTALL httpfs; LOAD httpfs;
INSTALL aws; LOAD aws;
CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);
ATTACH 'ducklake:data/mca_env.ducklake' AS lake
  (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');
```

## Known limitations / gotchas

- DuckDB cannot create `.ducklake` files on S3 — catalogue metadata must be a local file
- `COPY FROM DATABASE` fails on spatial types — tables are created individually
- `sfarrow` fails on DuckDB GeoParquet — use `arrow::read_parquet()` + `sf::st_as_sf()` in R
- Python `pins` cannot `pin_read` multi-file pins — use `arrow`/`duckdb` fallback
- DuckDB GeoParquet lacks CRS metadata — analysts must set CRS explicitly
- `curl` has a 2 GB upload limit — large tables use `pin_upload` with chunked Parquet files
- CRS for most spatial tables is EPSG:27700 (British National Grid); `ca_boundaries_bgc_tbl` is EPSG:4326
