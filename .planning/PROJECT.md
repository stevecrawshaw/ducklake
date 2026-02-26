# DuckLake

## What This Is

A data sharing platform that exports 18 curated tables from a local DuckDB database to S3, making them accessible to WECA analysts via pins (R/Python), a DuckLake SQL catalogue with time travel, and GeoParquet spatial files. Includes a single-command refresh pipeline and auto-generated data catalogue.

## Core Value

Analysts can discover and access curated, well-documented datasets from a shared catalogue without needing to know where or how the data is stored.

## Requirements

### Validated

- ✓ Export local DuckDB tables to parquet on S3 with metadata preserved — v1.0
- ✓ Reference S3 parquet files via pins in R — v1.0
- ✓ Reference S3 parquet files via pins in Python — v1.0
- ✓ Preserve table and column comments/metadata through the pipeline — v1.0 (403 column comments, all table comments)
- ✓ Create a DuckLake data lake instance over the S3 objects — v1.0 (18 tables, 12 views)
- ✓ Team analysts can query the data lake without local DuckDB setup — v1.0 (requires local .ducklake file)
- ✓ Dataset discovery — analysts can browse available tables and their descriptions — v1.0 (datasets_catalogue + columns_catalogue)

### Active

(None — planning next milestone)

### Out of Scope

- Real-time data pipelines — batch/manual upload sufficient for quarterly data
- Write access for analysts — read-only consumption, data governance concerns
- Web UI for browsing — command-line and notebook access is sufficient; analysts have R/Python
- Data transformation/ETL — source DuckDB is already curated
- Offline mode — analysts need S3 connectivity
- DuckLake catalogue sharing — .ducklake file must be distributed manually (DuckDB limitation)

## Context

Shipped v1.0 with 4,546 LOC across R, SQL, Python, and Quarto.
Tech stack: DuckDB/DuckLake, R (pins, sf, arrow), Python (pins, geopandas, pyarrow), AWS S3, Quarto.

- 18 tables exported: 10 non-spatial (26.4M rows incl. 19M EPC), 8 spatial (native GEOMETRY + GeoParquet)
- DuckLake catalogue with time travel (90-day retention), 12 pre-built views (4 source + 8 WECA-filtered)
- Auto-generated data catalogue: 30 datasets, 411 columns with descriptions and example values
- Unified refresh pipeline: single `Rscript scripts/refresh.R` re-exports everything
- Analyst guide: 863-line Quarto doc with WECA branding, executable examples, troubleshooting
- Known limitation: Python pins cannot `pin_read` multi-file pins (EPC table); use arrow/duckdb fallback
- Known limitation: DuckDB GeoParquet lacks CRS metadata; analysts must set CRS explicitly

## Constraints

- **Storage**: AWS S3 (`stevecrawshaw-bucket`, `eu-west-2`)
- **Languages**: Must work in both R and Python (team uses both)
- **Format**: Parquet for non-spatial, GeoParquet for spatial S3 objects
- **Auth**: AWS credentials via `.aws` config
- **Python**: Use `uv` for dependency management, Python 3.13+
- **DuckLake**: Catalogue metadata file (.ducklake) must be local — DuckDB cannot create on S3

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Parquet as interchange format | Wide support in R/Python/DuckDB, columnar efficiency | ✓ Good — universal compatibility confirmed |
| S3 as storage layer | Already provisioned, team familiar with AWS, pins supports S3 | ✓ Good |
| Pins for R/Python access | Unified abstraction for both languages over S3 | ✓ Good — Python multi-file limitation noted |
| Local .ducklake metadata file | DuckDB cannot create database files on S3 | ⚠️ Revisit — sharing mechanism needed |
| Individual CREATE TABLE for DuckLake | COPY FROM DATABASE fails on spatial types | ✓ Good — works reliably |
| DuckDB CLI for DuckLake operations | R duckdb package (v1.4.4) lacks ducklake extension | ⚠️ Revisit — monitor R package updates |
| GeoParquet for spatial pins | DuckDB COPY TO auto-generates GeoParquet 1.0.0 metadata | ✓ Good — R/Python roundtrip works |
| arrow+sf instead of sfarrow | sfarrow fails on DuckDB GeoParquet (missing CRS) | ✓ Good — more reliable |
| Chunked pin_upload for large tables | curl 2GB upload limit | ✓ Good — EPC table (19M rows) exports successfully |
| Source DB metadata for catalogue | DuckLake loses comments on DROP+CREATE refresh | ✓ Good — 404/411 columns described |
| 90-day snapshot retention | Time-based cleaner than version-count; snapshots are database-wide | ✓ Good |
| Dual-format Quarto output | HTML with SCSS + PDF via weca-report-typst | ✓ Good |

---
*Last updated: 2026-02-26 after v1.0 milestone*
