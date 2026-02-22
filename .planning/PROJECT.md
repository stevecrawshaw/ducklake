# DuckLake

## What This Is

A data sharing platform that takes tables from a local DuckDB database, uploads them as parquet files to S3, and makes them accessible to a team of WECA analysts via both R (pins) and Python. Metadata (table/column comments) from the source DuckDB is preserved throughout. The stretch goal is a DuckLake data lake instance for team-wide querying.

## Core Value

Analysts can discover and access curated, well-documented datasets from a shared catalogue without needing to know where or how the data is stored.

## Requirements

### Validated

(None yet — ship to validate)

### Active

- [ ] Export local DuckDB tables to parquet on S3 with metadata preserved
- [ ] Reference S3 parquet files via pins in R
- [ ] Reference S3 parquet files via pins in Python
- [ ] Preserve table and column comments/metadata through the pipeline
- [ ] Create a DuckLake data lake instance over the S3 objects
- [ ] Team analysts can query the data lake without local DuckDB setup
- [ ] Dataset discovery — analysts can browse available tables and their descriptions

### Out of Scope

- Real-time data pipelines — this is batch/manual upload of curated datasets
- Write access for analysts — read-only consumption
- Web UI for browsing — command-line and notebook access is sufficient for v1
- Data transformation/ETL — source DuckDB is already curated

## Context

- Source database is a local DuckDB file with multiple tables covering regional statistics (IMD, geographic boundaries, etc.)
- Metadata is stored in DuckDB's COMMENT facility (both table-level and column-level)
- WECA analysts use both R and Python; pins package provides a common abstraction for both
- AWS S3 bucket (`stevecrawshaw-bucket`, `eu-west-2`) already provisioned with credentials configured
- DuckLake is a relatively new DuckDB extension for data lake management — needs research
- Existing `aws_setup.r` demonstrates working S3/pins connectivity in R
- `pyproject.toml` already includes `duckdb`, `boto3`, `pins` dependencies

## Constraints

- **Storage**: AWS S3 (`stevecrawshaw-bucket`, `eu-west-2`) — already provisioned
- **Languages**: Must work in both R and Python (team uses both)
- **Format**: Parquet for S3 objects (columnar, efficient, wide tool support)
- **Auth**: AWS credentials via `.aws` config (already set up)
- **Python**: Use `uv` for dependency management, Python 3.13+

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Parquet as interchange format | Wide support in R/Python/DuckDB, columnar efficiency, metadata support | — Pending |
| S3 as storage layer | Already provisioned, team familiar with AWS, pins supports S3 | — Pending |
| Pins for R/Python access | Provides unified abstraction for both languages over S3 | — Pending |

---
*Last updated: 2026-02-22 after initialisation*
