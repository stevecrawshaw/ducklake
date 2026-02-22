# Stack Research

**Domain:** DuckDB-to-S3 data sharing platform with DuckLake
**Researched:** 2026-02-22
**Confidence:** MEDIUM (DuckLake is new/v0.3; pins versions unverifiable without web access)

## Recommended Stack

### Core Technologies

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| DuckDB | >=1.4.4 (currently in pyproject.toml) | Local analytical database, DuckLake engine | The entire project orbits DuckDB. v1.3.0+ required for DuckLake extension support. v1.4.4 already specified; use latest stable. |
| DuckLake extension (`ducklake`) | v0.3 (spec version) | Data lake format with Parquet storage on S3 | Purpose-built for exactly this use case: DuckDB tables -> Parquet on S3 with full metadata catalogue, time travel, schema evolution. Replaces manual Parquet export. |
| Python | 3.13+ | Primary scripting language for export pipeline | Already specified in `.python-version`. DuckDB Python bindings are mature. |
| R | 4.3+ | Consumer-side data access via pins | Team already uses R (see `aws_setup.r`). pins for R is more mature than Python equivalent. |
| AWS S3 | - | Data storage backend | Already in use (`stevecrawshaw-bucket`, `eu-west-2`). DuckLake natively supports S3 as DATA_PATH. |

### Supporting Libraries (Python)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `duckdb` | >=1.4.4 | Python bindings for DuckDB | All database operations, DuckLake ATTACH, migration script |
| `boto3` | >=1.42.54 | AWS SDK for S3 operations | Bucket policy management, IAM setup, pre-signed URLs. NOT needed for data operations (DuckDB handles S3 natively via httpfs). |
| `pins` | >=0.9.1 | Pin management for data sharing | Publishing individual tables as versioned pins on S3 for consumers who do not use DuckLake. |

### Supporting Libraries (R)

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `pins` | >=1.4.0 | S3 board for reading/writing pinned data | `board_s3()` for parquet pins. More mature than Python pins. |
| `arrow` | >=18.0 | Parquet read/write in R | Required by pins for parquet format support. |
| `duckdb` (R) | >=1.3.0 | DuckDB R bindings | Direct DuckLake access from R as alternative to pins. |
| `paws.storage` | latest | AWS S3 operations from R | Only if needing raw S3 operations outside pins. |
| `aws.s3` | latest | Alternative AWS S3 client | Already used in `aws_setup.r`. Simpler API than paws but less comprehensive. |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `uv` | Python package manager | Already configured. Use `uv add` for dependencies, `uv run` for execution. |
| DuckDB CLI | Interactive SQL for DuckLake management | `INSTALL ducklake; ATTACH 'ducklake:...'` for testing. Essential for debugging. |
| AWS CLI | S3 bucket management, IAM policies | Required for initial bucket setup, CORS, policies. |

## DuckLake Summary (from docs/ducklake-docs.md)

DuckLake is a lakehouse format (spec v0.3) with two components:

1. **Catalogue database** - Stores metadata in SQL tables (22 tables total). Options: DuckDB file (single client), SQLite (multiple local clients), PostgreSQL (multi-user remote).
2. **Data storage** - Parquet files on any storage backend DuckDB supports, including S3.

### Key DuckLake capabilities for this project

| Feature | How it works | Relevance |
|---------|--------------|-----------|
| **S3 data path** | `ATTACH 'ducklake:metadata.ducklake' (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/')` | Direct S3 storage without manual export |
| **COMMENT ON** | `COMMENT ON TABLE t IS '...'; COMMENT ON COLUMN t.c IS '...'` - stored in metadata catalogue | Preserves table/column comments from source DuckDB |
| **Tags** | `ducklake_tag` and `ducklake_column_tag` tables for arbitrary key-value metadata | Can store richer metadata than DuckDB comments |
| **Migration** | `COPY FROM DATABASE source TO ducklake;` for simple cases; Python migration script for complex cases | Direct migration path from existing DuckDB |
| **Geometry support** | Native geometry types in spec (point, polygon, multipolygon, etc.) | Handles WKB_BLOB spatial columns |
| **Time travel** | `SELECT * FROM t AT (VERSION => 3)` or `AT (TIMESTAMP => ...)` | Versioned data access for reproducibility |
| **Schema evolution** | ALTER TABLE ADD/DROP/RENAME COLUMN without rewriting data files | Future-proof schema changes |
| **Snapshots** | `FROM catalog.snapshots()` lists all commits with change tracking | Audit trail for data updates |
| **File pruning** | Per-file column statistics enable query pushdown | Efficient queries on large datasets |
| **Access control** | S3 IAM policies + PostgreSQL roles for reader/writer/superuser separation | Team access management |

### DuckLake unsupported features (relevant to this project)

- No indexes, primary keys, foreign keys, CHECK constraints
- No ENUM type (cast to VARCHAR)
- No sequences
- Migration script currently only supports local migrations (not direct S3); must migrate locally then move, or use `COPY FROM DATABASE` which does support S3

### Catalogue database recommendation for this project

**Use DuckDB file** as the catalogue database initially, because:
- Single writer is sufficient (one person manages data publishing)
- Simplest setup; no external database dependency
- The `.ducklake` file can be shared alongside the S3 data

**Graduate to SQLite** if multiple team members need to write concurrently from separate processes.

**Graduate to PostgreSQL** only if the team needs multi-user concurrent writes from different machines with access control at the catalogue level.

## Installation

```bash
# Python (via uv)
uv add duckdb boto3 pins

# R
install.packages(c("pins", "arrow", "duckdb"))
# Optional: install.packages(c("paws.storage", "aws.s3"))
```

```sql
-- DuckDB extensions (run once per DuckDB instance)
INSTALL ducklake;
INSTALL httpfs;  -- Required for S3 access
LOAD ducklake;
LOAD httpfs;
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| DuckLake | Manual Parquet export (`COPY TO 's3://.../*.parquet'`) | If you only need one-off exports without versioning, metadata, or time travel. Simpler but no catalogue. |
| DuckLake | Apache Iceberg | If the wider ecosystem (Spark, Trino, Athena) must read the data. Iceberg has broader tool support but DuckLake is simpler for DuckDB-centric workflows. |
| DuckLake | Delta Lake | Same rationale as Iceberg. Delta requires Spark ecosystem buy-in. |
| pins (S3 board) | Direct S3 Parquet reads (`arrow::read_parquet("s3://...")`) | If consumers are comfortable with raw S3 paths and don't need versioned pin metadata. |
| DuckDB catalogue (for DuckLake) | PostgreSQL catalogue | If team grows beyond 3-4 concurrent writers, or need fine-grained access control at the metadata level. |
| boto3 for S3 setup | AWS CLI only | If all S3 config can be done as one-off shell commands rather than programmatic setup. For this project, AWS CLI is likely sufficient. |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| MySQL as DuckLake catalogue | Officially warned against in DuckLake docs due to DuckDB MySQL connector limitations | DuckDB file, SQLite, or PostgreSQL |
| `aws.s3` R package for data reads | Unnecessary indirection when pins or DuckDB handle S3 natively | `pins::board_s3()` or `duckdb` R package with httpfs |
| Manual Parquet export scripts | Loses metadata, no versioning, no schema evolution, error-prone | DuckLake with `COPY FROM DATABASE` |
| Apache Iceberg/Delta for this scale | Over-engineered for 18 tables with a small team; requires JVM ecosystem | DuckLake |
| `pyarrow` for Parquet writing | DuckDB/DuckLake handles Parquet natively; adding pyarrow is redundant | DuckDB's built-in Parquet writer via DuckLake |

## Stack Patterns by Variant

**If only Python consumers:**
- Use DuckLake as primary access method
- Skip pins; consumers attach directly to DuckLake
- `duckdb.connect()` -> `ATTACH 'ducklake:...'` -> query tables

**If mixed R + Python consumers (this project):**
- Use DuckLake as the source of truth for data on S3
- Use pins as a parallel access layer for R users who want `board_s3()` simplicity
- Both point to the same S3 bucket but different prefixes (DuckLake manages its own paths; pins manages its own)

**If consumers need data without DuckDB:**
- pins is the better option; it writes standard Parquet files with a simple metadata manifest
- DuckLake's Parquet files are also readable directly, but the metadata is in the catalogue database

## Architecture Decisions

### Two-track access pattern

The project should support **two parallel access methods** to the same underlying data on S3:

1. **DuckLake track** - For DuckDB-native users (Python or R). Full metadata, time travel, schema evolution. Requires DuckDB + ducklake extension.
2. **Pins track** - For lightweight consumers. Versioned parquet pins on `board_s3()`. No DuckDB required; just `pins::pin_read()` or `pins.board_s3().pin_read()`.

These are not mutually exclusive. The export pipeline writes to both.

### Metadata preservation strategy

Source DuckDB has comments on tables and columns. These must transfer to both tracks:

- **DuckLake**: `COMMENT ON TABLE/COLUMN` is natively supported. Comments transfer via `COPY FROM DATABASE` or can be set manually.
- **Pins**: Use pin metadata (`pin_write(..., metadata = list(description = "...", columns = list(...)))`) to carry column descriptions.

### Spatial data (WKB_BLOB columns)

DuckLake spec v0.3 supports geometry types natively. The WKB_BLOB columns in the source DuckDB should map to DuckLake's geometry type. However:

- **Confidence: LOW** - Need to verify whether `COPY FROM DATABASE` handles the WKB_BLOB -> geometry conversion automatically, or whether manual casting is needed.
- For pins, geometry columns should be stored as WKB BLOB in Parquet (standard GeoParquet approach). R users read with `sf::st_read()` or `sfarrow`.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| DuckDB Python >=1.4.4 | DuckLake extension v0.3 | DuckLake requires DuckDB >= 1.3.0. v1.4.4 is confirmed compatible. |
| DuckDB R >=1.3.0 | DuckLake extension v0.3 | R users can also ATTACH to DuckLake directly. |
| pins (Python) >=0.9.1 | boto3 >=1.42.54 | pins uses boto3 under the hood for S3 boards. |
| pins (R) >=1.4.0 | arrow >=18.0 | arrow required for parquet pin type. |

## AWS S3 Configuration Required

For the `stevecrawshaw-bucket` in `eu-west-2`:

### DuckDB S3 Secret Setup

```sql
CREATE SECRET s3_secret (
    TYPE s3,
    PROVIDER credential_chain,
    REGION 'eu-west-2'
);
```

This uses the AWS credential chain (environment variables, `~/.aws/credentials`, IAM role). Avoids hardcoding keys.

### S3 Bucket Structure (Recommended)

```
s3://stevecrawshaw-bucket/
  ducklake/                    -- DuckLake data files (managed by DuckLake)
    main/                      -- Default schema
      table_name/              -- Per-table directories
        ducklake-*.parquet     -- Data files
  pins/                        -- Pins data (managed by pins package)
    table_name/                -- Per-pin directories
      YYYYMMDDTHHMMSSZ-xxxxx/ -- Versioned pin data
        data.parquet
```

### IAM Policy (Minimum for this project)

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "DuckLakeReadWrite",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": [
                "arn:aws:s3:::stevecrawshaw-bucket",
                "arn:aws:s3:::stevecrawshaw-bucket/*"
            ]
        }
    ]
}
```

For read-only consumers, restrict to `s3:GetObject` and `s3:ListBucket` only.

## Sources

- `docs/ducklake-docs.md` (local) -- DuckLake specification v0.3, full documentation including migration, S3 setup, access control, comments, geometry support. **HIGH confidence** for all DuckLake claims.
- `pyproject.toml` (local) -- Current project dependencies: duckdb>=1.4.4, boto3>=1.42.54, pins>=0.9.1. **HIGH confidence**.
- `aws_setup.r` (local) -- Existing R setup using `pins::board_s3()`, `arrow`, `aws.s3`. **HIGH confidence** for R patterns.
- Training data -- pins R/Python API, boto3, general DuckDB knowledge. **LOW-MEDIUM confidence** for specific version claims (WebSearch/WebFetch unavailable to verify current releases).

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| DuckLake capabilities | HIGH | Verified against local docs (3600+ lines of official documentation) |
| DuckLake + S3 integration | HIGH | Explicit examples in docs for S3 DATA_PATH, secrets, access control |
| Migration path (COPY FROM DATABASE) | HIGH | Documented with examples; caveats noted for unsupported features |
| Geometry/spatial handling | MEDIUM | DuckLake spec supports geometry types, but WKB_BLOB conversion path unclear |
| pins (R) for S3 | MEDIUM | Working code in `aws_setup.r`; version claims from training data |
| pins (Python) for S3 | LOW | In pyproject.toml but no working code yet; API details from training data only |
| Specific library versions | LOW | Could not verify latest releases (WebSearch/WebFetch unavailable) |

## Open Questions

1. **WKB_BLOB migration**: Does `COPY FROM DATABASE` automatically handle WKB_BLOB spatial columns, or do they need manual casting to DuckLake's geometry type?
2. **pins Python + parquet on S3**: Verify that `pins.board_s3()` in Python supports parquet type with metadata. The R version definitely does.
3. **DuckLake metadata file sharing**: Can the `.ducklake` catalogue file be placed on S3 (or must it be local/PostgreSQL)? The docs suggest DuckDB file must be local, but SQLite/PostgreSQL can be remote.
4. **Comments in COPY FROM DATABASE**: Does the migration command preserve `COMMENT ON TABLE/COLUMN` metadata, or must comments be re-applied manually?
5. **Current stable DuckDB version**: Verify that 1.4.4 is still the latest, or whether a newer version exists.

---
*Stack research for: DuckDB-to-S3 data sharing platform with DuckLake*
*Researched: 2026-02-22*
