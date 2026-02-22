# Project Research Summary

**Project:** DuckLake — DuckDB-to-S3 data sharing platform
**Domain:** Internal data lake with dual-access publishing (DuckLake + pins)
**Researched:** 2026-02-22
**Confidence:** MEDIUM-HIGH

## Executive Summary

This project publishes an 18-table local DuckDB database to AWS S3 so a mixed R/Python analyst team can access it. The recommended approach is a dual-track architecture: DuckLake (v0.3) as the primary lake format for SQL-capable consumers, and pins-on-S3 as a simpler access path for analysts who just need `pin_read("table_name")`. Both tracks write to the same S3 bucket under separate prefixes (`ducklake/` and `pins/`), with DuckLake managing its own file lifecycle independently from pins. The DuckLake catalogue is a DuckDB file stored on S3, which is sufficient for this project's single-writer, multi-reader usage pattern.

The recommended stack is lean and already mostly in place: DuckDB >=1.4.4 with the `ducklake` and `httpfs` extensions, Python `pins` and `boto3` (already in `pyproject.toml`), and R `pins` + `arrow` (already demonstrated in `aws_setup.r`). DuckLake eliminates the need for manual Parquet export scripts and provides time travel, schema evolution, and metadata preservation at no additional implementation cost. The `COPY FROM DATABASE` migration command handles bulk initial load for non-spatial tables, but spatial tables require explicit `ST_GeomFromWKB()` conversion before export.

The primary risks are all resolvable with upfront design decisions: WKB_BLOB geometry columns must be converted before any data leaves DuckDB (to native GEOMETRY type for DuckLake, to WKT text for pins); column comments must be extracted programmatically and applied after migration (DuckLake supports `COMMENT ON` natively; pins requires custom metadata); and the 19M-row EPC table requires partitioned or multi-file export to avoid OOM and S3 upload limits. AWS credentials must use `credential_chain` from day one — static keys in code are a pre-commit hook violation and a rotation nightmare.

## Key Findings

### Recommended Stack

The project already has its core dependencies declared. DuckLake v0.3 (installed via `INSTALL ducklake` in DuckDB) is the right lake format for this use case: it is purpose-built for DuckDB-centric workflows, supports S3 natively via `httpfs`, stores metadata in 22 catalogue tables, and provides time travel, schema evolution, and geometry support without requiring the JVM ecosystem that Iceberg or Delta would demand. The catalogue backend should be a DuckDB file stored on S3 — simple, dependency-free, and sufficient for a single writer.

**Core technologies:**
- **DuckDB >=1.4.4** with `ducklake` + `httpfs` + `spatial` extensions — central engine for both reading source data and writing to DuckLake on S3
- **DuckLake extension v0.3** — lake format replacing manual Parquet export; provides metadata catalogue, time travel, and geometry support
- **Python `pins` >=0.9.1** + **R `pins` >=1.4.0** — parallel simple-access track for analysts who do not use DuckDB
- **AWS S3 `stevecrawshaw-bucket` (eu-west-2)** — already in use; needs separate `ducklake/` and `pins/` prefixes
- **`boto3` >=1.42.54** — AWS SDK for S3 setup and IAM; not needed for data operations (DuckDB handles those natively)

Avoid: MySQL as DuckLake catalogue (officially unsupported), manual Parquet export scripts (loses metadata), Apache Iceberg/Delta (over-engineered for this scale and team), and `pyarrow` for Parquet writing (DuckLake handles this natively).

### Expected Features

The feature set divides cleanly into three tiers. The P1 features are the minimum viable platform; P2 makes it genuinely better than alternatives; P3 is post-launch evolution once usage patterns are established.

**Must have (table stakes):**
- S3 Parquet export pipeline — nothing exists to share without this; must handle the 19M-row EPC table
- Metadata preservation (table + column comments) — the README explicitly identifies comments as a core data asset
- R access via `pins::board_s3()` + `pin_read()` — half the team's expected workflow
- Python access via `pins.board_s3()` + `board.pin_read()` — the other half
- AWS credential documentation and read-only IAM policy for analyst accounts

**Should have (competitive advantage over shared drives):**
- DuckLake catalogue setup with `ATTACH 'ducklake:s3://...'` — enables SQL querying, joins, and filtering without downloading data
- `COMMENT ON TABLE/COLUMN` metadata in DuckLake — native DuckLake support at no extra cost once the catalogue is set up
- Spatial geometry conversion (WKB_BLOB → native geometry for DuckLake; WKB_BLOB → WKT for pins)
- Data catalogue manifest — queryable table-of-tables for new team member onboarding
- DuckLake views for common queries

**Defer (v2+):**
- Automated refresh workflow — manual is fine while the platform is establishing; automate once refresh cadence is clear
- DuckLake data change feed — only valuable once multiple refresh cycles have occurred
- Table partitioning for the EPC table — defer unless query performance is demonstrably poor
- PostgreSQL metadata backend — only needed if concurrent write access becomes necessary (unlikely)

### Architecture Approach

The system is a classic ETL with dual sinks. A single Python export pipeline reads the source `mca_env_base.duckdb` once, extracts metadata (table + column comments via `duckdb_tables()` and `duckdb_columns()`), transforms spatial columns (WKB_BLOB → GEOMETRY / WKT), then writes to two independent sinks: DuckLake via `ATTACH` + `CREATE TABLE AS SELECT` + `COMMENT ON`, and pins via `board_s3()` + `pin_write()`. The two sinks do not share Parquet files — DuckLake manages its own file lifecycle under `ducklake/` and would break pins if they shared files.

**Major components:**
1. **Source reader** (`src/source.py`) — reads source DuckDB, enumerates tables, extracts metadata, identifies spatial columns; no S3 needed
2. **DuckLake exporter** (`src/export_ducklake.py`) — owns `ATTACH 'ducklake:...'`, `CREATE TABLE AS SELECT`, and `COMMENT ON` flow
3. **pins exporter** (`src/export_pins.py`) — owns `board_s3()` setup and `pin_write()` calls; handles WKT conversion for spatial columns
4. **Spatial converter** (`src/spatial.py`) — isolated geometry conversion utilities; the highest-risk component
5. **Config** (`src/config.py`) — centralised S3 bucket, region, and path constants
6. **Refresh orchestrator** (`src/refresh.py`) — full drop-and-recreate strategy for periodic updates; DuckLake snapshots preserve history

### Critical Pitfalls

1. **WKB_BLOB geometry silently becomes raw binary** — load the `spatial` extension and convert via `ST_GeomFromWKB()` before any export; validate with `typeof(geom_col)` returning `GEOMETRY` not `BLOB`; this must be done in Phase 1 before data leaves DuckDB
2. **Column comments lost in migration** — for DuckLake, apply `COMMENT ON` after `COPY FROM DATABASE` (comments are not migrated automatically); for pins, extract comments with `duckdb_columns()` and store as custom pin metadata; skipping this loses institutional knowledge permanently
3. **19M-row EPC table OOM or timeout** — use `per_thread_output` for DuckLake export; tune `ROW_GROUP_SIZE`; verify boto3 multipart upload is enabled for pins; monitor for single Parquet files exceeding 5 GB (S3 upload limit)
4. **AWS credentials hardcoded in scripts** — use `CREATE SECRET (TYPE s3, PROVIDER credential_chain, REGION 'eu-west-2')` in DuckDB; use environment-sourced credentials for pins; per-user IAM roles with reader/writer separation; pre-commit hooks already scan for secrets
5. **DuckLake has no PRIMARY KEY or UNIQUE constraints** — audit source tables for constraint-dependent deduplication logic; rewrite any `INSERT ... ON CONFLICT` patterns as `MERGE INTO`; add row count validation checks to the refresh pipeline

## Implications for Roadmap

Based on research, the dependencies are clear: S3 access and credentials must exist before any data can be written; source reading and metadata extraction can be built and tested locally first; pins and DuckLake exports are independent of each other once source reading works; spatial handling is the riskiest component and should be isolated to its own phase.

### Phase 0: Infrastructure and Credentials

**Rationale:** Nothing else can proceed without S3 access and IAM roles. This is a prerequisite for all other phases, not an implementation phase. Setting it up correctly (credential chain, reader/writer separation) prevents the credentials pitfall permanently.
**Delivers:** Working AWS credentials via `credential_chain`; S3 bucket prefixes (`ducklake/`, `pins/`); read-only IAM policy for analyst accounts; DuckDB S3 secret configuration tested locally.
**Addresses:** AWS credential management (P1 feature); security foundation for all subsequent phases.
**Avoids:** Pitfall 5 (hardcoded credentials); S3 region misconfiguration (`eu-west-2` must be explicit).

### Phase 1: Source Reading and Metadata Extraction

**Rationale:** All export logic depends on correctly reading the source DuckDB and extracting metadata. This phase can be built and unit-tested entirely without S3, reducing risk. It also forces early discovery of any schema surprises (ENUMs, unsupported types) that would block DuckLake migration.
**Delivers:** `src/source.py` with table enumeration, metadata extraction (`duckdb_tables()`, `duckdb_columns()`), and spatial column identification; test coverage; documented metadata dictionary structure.
**Addresses:** Metadata preservation (P1); spatial data identification for later conversion.
**Avoids:** Pitfall 2 (comments lost — must know what comments exist before writing export code); discovering unsupported types too late.

### Phase 2: pins Export (Non-Spatial Tables)

**Rationale:** pins is the simpler access path and delivers immediate value to analysts before DuckLake is set up. Non-spatial tables first isolates the spatial complexity. Cross-language compatibility (R + Python) must be validated here before the full pipeline is built.
**Delivers:** `src/export_pins.py`; all non-spatial tables published to `s3://stevecrawshaw-bucket/pins/` with title and column description metadata; verified `pin_read()` from both R and Python.
**Uses:** Python `pins` >=0.9.1, R `pins` >=1.4.0, `arrow` for Parquet type, boto3 for S3 authentication.
**Avoids:** Pitfall 6 (R/Python pins incompatibility — validate cross-language reads here); Pitfall 4 (EPC large table — verify multipart upload).

### Phase 3: DuckLake Export (Non-Spatial Tables)

**Rationale:** DuckLake setup is independent of pins. Non-spatial tables first, because `COPY FROM DATABASE` is the fast path for bulk load but its handling of WKB_BLOB is unverified. Validating the DuckLake catalogue, schema, comments, and time travel on simpler tables reduces risk before tackling spatial.
**Delivers:** `src/export_ducklake.py`; DuckLake catalogue at `s3://stevecrawshaw-bucket/ducklake/metadata.ducklake`; all non-spatial tables with `COMMENT ON` metadata; verified `ATTACH` from separate DuckDB session.
**Uses:** DuckDB `ducklake` + `httpfs` extensions; `COPY FROM DATABASE` or `CREATE TABLE AS SELECT` per table.
**Avoids:** Pitfall 3 (no primary keys — document `MERGE INTO` pattern here); Pitfall 2 (comments — verify `COMMENT ON` is applied after bulk copy).

### Phase 4: Spatial Data Handling

**Rationale:** Spatial is isolated because it is the riskiest component. The WKB_BLOB → GEOMETRY conversion path for DuckLake needs validation; the WKB_BLOB → WKT path for pins is more certain but still needs testing with downstream R `sf` and Python `shapely` consumers. Doing this as a dedicated phase means failures here do not block the rest of the pipeline.
**Delivers:** `src/spatial.py` with WKB conversion utilities; spatial tables exported via both DuckLake (native geometry) and pins (WKT); verified geometry roundtrip in R (`sf::st_as_sf()`) and Python (`shapely.from_wkt()`).
**Avoids:** Pitfall 1 (WKB_BLOB silent degradation — this is the entire focus of the phase); geometry columns appearing as raw bytes in consumer data frames.

### Phase 5: Refresh Pipeline and Maintenance

**Rationale:** Once all tables are exported via both paths, the refresh pipeline makes the platform operational rather than a one-off migration. The idempotent drop-and-recreate strategy is simpler than incremental merge and safe given DuckLake's snapshot-based time travel preserving history.
**Delivers:** `src/refresh.py` with full re-export orchestration; DuckLake snapshot management (`CHECKPOINT`); pins version management; row count validation after each refresh; documented refresh process.
**Addresses:** Automated refresh (P3 feature, brought forward as the platform needs to be maintainable); DuckLake compaction schedule.
**Avoids:** Pitfall 3 (duplicate rows without primary keys — validation checks built into refresh); tiny Parquet file accumulation from incremental inserts.

### Phase 6: Consumer Documentation and Data Catalogue

**Rationale:** The platform is only useful if analysts can discover and access data independently. Documentation and a data catalogue manifest are the final deliverables that make the platform self-service.
**Delivers:** Consumer guide for DuckLake access (DuckDB `ATTACH` from R and Python); consumer guide for pins access (R and Python `pin_read()` workflows); data catalogue manifest view in DuckLake; spatial data access patterns documented.
**Addresses:** Table/column discovery (P1 feature); data catalogue manifest (P2 feature); DuckLake views (P2 feature).

### Phase Ordering Rationale

- Phase 0 before everything: S3 credentials are a hard dependency.
- Phase 1 before Phases 2 and 3: metadata extraction is consumed by both export paths.
- Phases 2 and 3 can run concurrently: pins and DuckLake exports are independent once Phase 1 is complete. In practice, pins first gives faster analyst value.
- Phase 4 after Phases 2 and 3: spatial handling extends working non-spatial exports; better to have a working baseline before tackling the riskiest component.
- Phase 5 after Phase 4: all tables must be exportable before a refresh pipeline makes sense.
- Phase 6 last: documentation and catalogue are built on top of a working, validated platform.

### Research Flags

Phases likely needing deeper research during planning:
- **Phase 4 (Spatial):** WKB_BLOB → DuckLake native geometry conversion path is LOW confidence. Needs a focused `ST_GeomFromWKB()` + DuckLake geometry type validation spike before committing to implementation.
- **Phase 2 (pins cross-language):** pins R/Python interoperability is LOW confidence from research. Needs a cross-language read test with a representative sample (including large tables) as the first task.

Phases with well-documented patterns (skip research-phase):
- **Phase 0 (Infrastructure):** AWS IAM + DuckDB `credential_chain` pattern is well-documented.
- **Phase 1 (Source Reading):** Standard DuckDB Python API; `duckdb_tables()` and `duckdb_columns()` are stable.
- **Phase 3 (DuckLake Export):** `COPY FROM DATABASE` and `COMMENT ON` are extensively documented in the local DuckLake docs.
- **Phase 5 (Refresh):** Drop-and-recreate with DuckLake snapshots is a documented pattern.

## Confidence Assessment

| Area | Confidence | Notes |
|------|------------|-------|
| Stack | MEDIUM | DuckLake capabilities HIGH (verified against 3600-line local docs); specific library version claims LOW (no web access to verify current releases) |
| Features | MEDIUM-HIGH | DuckLake features HIGH; pins capabilities MEDIUM (working R code exists; Python API from training data only) |
| Architecture | HIGH | Two-track pattern is well-reasoned; DuckLake path structure confirmed in docs; pins S3 board confirmed in working `aws_setup.r` |
| Pitfalls | MEDIUM-HIGH | DuckLake-specific pitfalls HIGH (from spec); pins cross-language and spatial conversion are MEDIUM (training data, needs validation) |

**Overall confidence:** MEDIUM-HIGH

### Gaps to Address

- **WKB_BLOB → DuckLake geometry conversion:** Whether `COPY FROM DATABASE` handles this automatically or requires manual `ST_GeomFromWKB()` is unverified. Must test with a spatial table before committing to the spatial phase design.
- **pins Python + parquet on S3 with custom metadata:** R version is verified in working code; Python version needs a validation spike.
- **DuckLake `COMMENT ON` preservation via `COPY FROM DATABASE`:** Research notes this may not transfer automatically and must be re-applied. Verify in Phase 3.
- **DuckLake catalogue file on S3:** Research states this is supported for single-writer scenarios but needs a working test to confirm. If it does not work, the fallback is a local catalogue with manual S3 sync.
- **pins R/Python cross-language compatibility for Parquet type:** Single "writer language" recommendation is conservative; actual compatibility should be validated early in Phase 2.

## Sources

### Primary (HIGH confidence)
- `docs/ducklake-docs.md` (local) — DuckLake specification v0.3; migration, S3 storage, access control, comments, geometry types, unsupported features, compaction, expiry
- `aws_setup.r` (local) — working R pins `board_s3()` + `pin_write()` + `pin_read()` with parquet type
- `pyproject.toml` (local) — confirmed dependencies: `duckdb>=1.4.4`, `boto3>=1.42.54`, `pins>=0.9.1`
- `.python-version` (local) — Python 3.13+

### Secondary (MEDIUM confidence)
- Training data — pins R/Python S3 board API, DuckDB spatial extension WKB handling, large Parquet file performance characteristics
- `README.md`, `PROJECT.md` (local) — project goals and context; informs feature prioritisation

### Tertiary (LOW confidence)
- Training data — specific library version currency (duckdb, pins, arrow latest releases); pins R/Python cross-language compatibility edge cases

---
*Research completed: 2026-02-22*
*Ready for roadmap: yes*
