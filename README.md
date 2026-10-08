# WECA Data Platform (DuckLake)

> [!WARNING]
> **Mothballed (October 2026).** This project is no longer maintained. The S3 data (DuckLake Parquet files and pins) has been deleted and the analyst guide is no longer published. None of the access instructions below work any more. To rebuild, run `Rscript scripts/refresh.R` against `mca_env_base.duckdb` with a new S3 bucket.

A shared data lake providing **18 curated datasets** for analysts at the West of England Combined Authority. Data is stored on Amazon S3 and accessible through two complementary routes:

- **Pins (R / Python):** Read datasets directly into data frames for exploratory analysis
- **DuckLake (SQL via DuckDB):** Query with SQL, join across tables, use pre-built WECA-filtered views, and browse the data catalogue

Both routes read from the same underlying Parquet files on S3.

**Analyst guide (full setup + examples):** https://stevecrawshaw.github.io/ducklake/

---

## What's included

| Resource | Count | Notes |
|----------|-------|-------|
| Base tables | 18 | 10 non-spatial + 8 spatial (GeoParquet) |
| WECA-filtered views | 12 | 4 non-spatial + 8 `*_weca_vw` spatial |
| Documented columns | 403 | See `columns_catalogue` |
| Spatial datasets | 8 | Boundaries, postcodes, UPRN addresses |

Catalogue tables (`datasets_catalogue`, `columns_catalogue`) are self-describing — query them first to understand what's available.

---

## Prerequisites

| Tool | Minimum version | Purpose |
|------|-----------------|---------|
| DuckDB CLI | **1.5.2** | DuckLake SQL queries |
| R | 4.x | `pins` access and pipeline scripts |
| Python | 3.13 | Pin validation and `main.py` |
| AWS credentials | — | `~/.aws/credentials` for `stevecrawshaw-bucket` |

> **Note:** The R `duckdb` package cannot load the `ducklake` extension. Use the DuckDB **CLI** for all DuckLake queries.

---

## Quick start — DuckDB CLI

```sql
INSTALL ducklake; LOAD ducklake;
INSTALL httpfs;   LOAD httpfs;
INSTALL aws;      LOAD aws;

CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);

ATTACH 'ducklake:data/mca_env.ducklake' AS lake
  (READ_ONLY, DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

-- Browse the catalogue
SELECT * FROM lake.datasets_catalogue ORDER BY type, name;

-- Query a WECA-filtered view
SELECT * FROM lake.epc_domestic_weca_vw LIMIT 100;
```

## Quick start — R (pins)

```r
library(pins)

board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  prefix = "pins/",
  region = "eu-west-2",
  versioned = TRUE
)

pin_list(board)                          # list all datasets
df <- pin_read(board, "ca_la_lookup_tbl")
```

## Quick start — Python (pins)

```python
from pins import board_s3

board = board_s3("stevecrawshaw-bucket", prefix="pins/")
board.pin_list()
df = board.pin_read("ca_la_lookup_tbl")
```

---

## Repository structure

```
ducklake/
├── data/
│   └── mca_env.ducklake      # DuckLake catalogue metadata (local, KB-sized)
├── scripts/
│   ├── refresh.R             # Unified pipeline entry point (run this)
│   ├── create_ducklake.R     # One-time catalogue creation
│   ├── export_pins.R         # Non-spatial pin export to S3
│   ├── export_spatial_pins.R # Spatial GeoParquet export to S3
│   ├── create_views.sql      # 12 WECA-filtered view definitions
│   ├── apply_comments.R      # Column/table metadata comments
│   └── migrate_ducklake.R    # One-time 0.x → 1.0 migration
├── docs/
│   └── analyst-guide.qmd    # Full analyst guide (Quarto)
├── aws_setup.r               # AWS credential helper
└── main.py                   # Python entry point
```

---

## Running the pipeline (maintainers)

All scripts run from the project root. The source database (`~/projects/data-lake/data_lake/mca_env_base.duckdb`) is read-only — this project does not own it.

```bash
# Full refresh: re-exports all 18 tables to DuckLake + S3 pins, regenerates catalogues
Rscript scripts/refresh.R

# One-time: create the DuckLake catalogue from scratch
Rscript scripts/create_ducklake.R

# Apply column/table comments and create views (run after create_ducklake.R)
Rscript scripts/apply_comments.R

# Validate all S3 pins
uv run python scripts/validate_pins.py

# One-time: upgrade a 0.x catalogue to 1.0
Rscript scripts/migrate_ducklake.R
```

### Data flow

```
mca_env_base.duckdb (source, read-only)
       │
       ├─► DuckLake CLI export ──► data/mca_env.ducklake (catalogue metadata)
       │                            + s3://stevecrawshaw-bucket/ducklake/data/ (Parquet)
       │
       └─► Pins export ──────────► s3://stevecrawshaw-bucket/pins/ (Parquet / GeoParquet)
```

`refresh.R` runs in six steps: pre-flight → DuckLake DROP+CREATE → row count validation → pin export → `datasets_catalogue` → `columns_catalogue`.

### Python environment

```bash
uv sync                              # install dependencies
uv run python scripts/validate_pins.py
```

### Docs

```bash
quarto render docs   # render locally
quarto preview docs  # live preview
```

Docs auto-deploy to GitHub Pages on push to `main` when files under `docs/` change.

---

## Known limitations

| Issue | Detail |
|-------|--------|
| Catalogue must be local | DuckDB cannot create `.ducklake` files on S3 |
| `COPY FROM DATABASE` broken for spatial | Tables with geometry columns must be created individually |
| Multi-file pins | Python `pins` cannot `pin_read` multi-file pins — use `arrow`/`duckdb` fallback |
| GeoParquet lacks CRS metadata | Analysts must set CRS explicitly; most tables are EPSG:27700, `ca_boundaries_bgc_tbl` is EPSG:4326 |
| `sfarrow` incompatibility | Use `arrow::read_parquet()` + `sf::st_as_sf()` in R instead |
| Large table uploads | `curl` has a 2 GB limit — large tables use chunked `pin_upload` (3 M rows/chunk) |
| Mixed geometry types | `ca_boundaries_bgc_tbl` uses `ST_Multi()` to promote POLYGON → MULTIPOLYGON |
| Invalid geometries | `lsoa_2021_lep_tbl` has a `geom_valid` BOOLEAN column flagging invalid rows |

---

## AWS configuration

- **Region:** `eu-west-2` (London)
- **Bucket:** `stevecrawshaw-bucket`
- **DuckLake data:** `s3://stevecrawshaw-bucket/ducklake/data/`
- **Pins:** `s3://stevecrawshaw-bucket/pins/`
- **Auth:** credential chain via `~/.aws/credentials`

---

## Related docs

- [Analyst Guide](https://stevecrawshaw.github.io/ducklake/) — full setup, examples, and spatial data notes
- [DuckLake extension docs](https://duckdb.org/docs/extensions/ducklake) — time travel, snapshots, catalogue schema
- [pins for R](https://pins.rstudio.com/) — board setup and `pin_read` reference
