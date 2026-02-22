# Pitfalls Research

**Domain:** DuckDB-to-S3 data sharing platform (DuckLake, pins, parquet export with spatial data)
**Researched:** 2026-02-22
**Confidence:** MEDIUM (DuckLake docs verified directly; pins and spatial export based on project files and training data)

## Critical Pitfalls

### Pitfall 1: WKB_BLOB Geometry Columns Silently Degrade in Parquet Export

**What goes wrong:**
DuckDB stores spatial data as `WKB_BLOB` (Well-Known Binary in a BLOB column). When exporting to plain Parquet via `COPY ... TO ... (FORMAT PARQUET)`, the column is written as an opaque binary blob without spatial metadata. Downstream consumers (R `sf`, Python `geopandas`, QGIS) cannot interpret the column as geometry without manual conversion. Worse, DuckLake's specification supports native `geometry` types in Parquet (using the GeoParquet standard), but only if the data is stored as DuckDB's `GEOMETRY` type, not as raw `WKB_BLOB`.

**Why it happens:**
The original DuckDB database likely stores spatial data as `WKB_BLOB` because the data was imported from a source that uses WKB encoding. DuckDB's `spatial` extension can convert between WKB and native GEOMETRY, but this step is easily overlooked during export or migration. DuckLake's geometry support (documented in the spec as `point`, `linestring`, `polygon`, etc.) requires proper geometry-typed columns, not raw blobs.

**How to avoid:**
1. Before migration, convert `WKB_BLOB` columns to DuckDB's native `GEOMETRY` type using `ST_GeomFromWKB(wkb_column)`.
2. Validate with `SELECT typeof(geom_col) FROM table LIMIT 1` -- must return `GEOMETRY`, not `BLOB`.
3. When using DuckLake, confirm the column appears in `ducklake_column` with a geometry type, not `blob`.
4. If exporting to standalone Parquet (for pins), use `COPY (SELECT *, ST_AsWKB(geom) AS geometry FROM tbl) TO 'file.parquet'` with the GeoParquet metadata written by DuckDB's spatial extension.

**Warning signs:**
- Column type shows as `BLOB` rather than `GEOMETRY` in schema inspection.
- Downstream R/Python reads the column as raw bytes rather than spatial objects.
- `pin_read()` returns a data frame with a binary column instead of an `sf` geometry column.

**Phase to address:**
Phase 1 (Data Export/Migration) -- must be resolved before any data leaves DuckDB.

---

### Pitfall 2: DuckDB Column Comments/Metadata Lost During Migration to DuckLake or Parquet

**What goes wrong:**
The source DuckDB database stores table and column descriptions in the `COMMENT ON` metadata system. When migrating to DuckLake, comments are preserved (DuckLake supports `COMMENT ON TABLE` and `COMMENT ON COLUMN`). However, when exporting to standalone Parquet files for pins, **all comments are lost** -- Parquet has no standard mechanism for storing column descriptions. The README explicitly states "Metadata for the tables in the local duckdb database is in the comments field", so this is a core data asset, not optional decoration.

**Why it happens:**
Parquet files store schema information (column names, types) and file-level key-value metadata, but DuckDB's `COPY TO` does not propagate DuckDB `COMMENT ON` values into Parquet key-value metadata. There is no automatic mechanism to bridge these.

**How to avoid:**
1. For the DuckLake path: Comments transfer naturally via `COMMENT ON` -- verified in DuckLake docs. Use this as the primary metadata-preserving pathway.
2. For the pins/Parquet path: Extract comments programmatically from the source DuckDB (`SELECT * FROM duckdb_columns() WHERE comment IS NOT NULL`) and write a companion metadata file (JSON or YAML) that ships alongside each pin.
3. Consider using Parquet file-level key-value metadata (`key_value_metadata` parameter in DuckDB's `COPY TO`) to embed column descriptions, though this is non-standard and readers may ignore it.
4. DuckLake also supports tags (`ducklake_tag` and `ducklake_column_tag` tables) which could store richer metadata than plain comments.

**Warning signs:**
- After migration, `COMMENT ON` returns NULL for columns that had descriptions.
- Team members cannot find data dictionaries or column meanings.
- Pin consumers have no context for what columns mean.

**Phase to address:**
Phase 1 (Data Export/Migration) -- design the metadata preservation strategy before writing any export code.

---

### Pitfall 3: DuckLake Has No Primary Keys or Unique Constraints -- Upsert Logic Must Change

**What goes wrong:**
DuckLake explicitly does not support `PRIMARY KEY`, `FOREIGN KEY`, `UNIQUE`, or `CHECK` constraints (documented as "unlikely to be supported in the future"). If the source DuckDB database relies on primary keys for deduplication or upsert logic during periodic refreshes, this logic will silently break. `INSERT ... ON CONFLICT` syntax does not work in DuckLake; only `MERGE INTO` is supported.

**Why it happens:**
Primary key constraints are "prohibitively expensive to enforce in data lake setups" per the DuckLake docs. Teams accustomed to relational database guarantees assume the same patterns will work.

**How to avoid:**
1. Audit all tables in the source DuckDB for primary key or unique constraints. Document which tables rely on deduplication.
2. Rewrite any `INSERT ... ON CONFLICT` patterns to use `MERGE INTO` syntax for DuckLake.
3. For periodic data refreshes (e.g., re-importing EPC data), decide between full table replacement (`DROP TABLE` + `CREATE TABLE AS`) or incremental `MERGE INTO` with explicit match conditions.
4. Consider that without enforced uniqueness, duplicate rows can silently accumulate if refresh logic has bugs. Build validation checks (e.g., `SELECT COUNT(*) vs COUNT(DISTINCT key_col)`) into the refresh pipeline.

**Warning signs:**
- `CREATE TABLE` with `PRIMARY KEY` clause fails or is silently ignored in DuckLake.
- Duplicate rows appear after a data refresh cycle.
- `INSERT ... ON CONFLICT` throws an error.

**Phase to address:**
Phase 2 (DuckLake Setup) -- must redesign data loading patterns before implementing refresh logic.

---

### Pitfall 4: 19M-Row EPC Table Causes Timeout or OOM During Single-Transaction Export

**What goes wrong:**
The `raw_domestic_epc_certificates_tbl` table has 19.3 million rows and 93 columns. Exporting this as a single Parquet file, or inserting it into DuckLake in a single transaction, can exhaust memory or take excessively long. DuckDB's default Parquet writer settings may produce a single massive file that is slow to read from S3. When using pins, the default upload may also hit S3 multipart upload limits or timeout.

**Why it happens:**
DuckDB is efficient at columnar operations but a 93-column, 19M-row table is substantial (likely 5-15 GB in Parquet depending on compression). Default settings produce a single file. S3 uploads of large files without multipart support fail at 5 GB. The pins package may not handle multipart uploads gracefully.

**How to avoid:**
1. For DuckLake: Use the `per_thread_output` option (set to `true`) to write multiple Parquet files in parallel. DuckLake's `target_file_size` defaults to 512 MB -- this is reasonable, but verify it is producing multiple files rather than one monolithic file.
2. For pins/Parquet export: Partition the export by a sensible column (e.g., `local_authority_code` or date range) to produce multiple smaller files. Or export as a single file but with `ROW_GROUP_SIZE` tuned down (e.g., 100,000 rows per row group) for better read performance.
3. Use `zstd` compression (DuckLake default is already `zstd` level 3) to reduce file size.
4. For S3 uploads: Ensure boto3 is configured with multipart upload enabled (default threshold is 8 MB, which should handle this automatically).
5. Monitor memory usage during export. DuckDB can stream exports, but some operations materialise the full result.

**Warning signs:**
- Export/insert operation hangs for more than a few minutes.
- Python process killed by OOM.
- S3 upload fails with "EntityTooLarge" error.
- Single Parquet file exceeds 5 GB.

**Phase to address:**
Phase 1 (Data Export) for pins path; Phase 2 (DuckLake Setup) for DuckLake path.

---

### Pitfall 5: AWS Credentials Hardcoded or Shared as Static Keys Across Team

**What goes wrong:**
The `aws_setup.r` file references "aws credentials are in .aws and keeper". Static IAM access keys shared between team members create a security risk and make rotation painful. If one person's key is compromised, all access must be rotated. The DuckLake access control guide shows explicit `KEY_ID` and `SECRET` values in SQL -- tempting to copy-paste into scripts that get committed.

**Why it happens:**
Static keys are the path of least resistance. DuckDB's secret manager requires explicit key/secret values. Teams default to sharing a single IAM user's credentials.

**How to avoid:**
1. Use IAM roles with AWS SSO/Identity Centre rather than static access keys. DuckDB supports `PROVIDER credential_chain` which reads from environment variables, instance profiles, and SSO.
2. If static keys are unavoidable, use per-user IAM users with scoped policies (reader vs writer as shown in DuckLake access control docs).
3. Never commit AWS credentials. Use `.env` files (in `.gitignore`) or AWS profiles in `~/.aws/credentials`.
4. DuckDB secrets can use `PROVIDER credential_chain` to automatically pick up credentials from the environment:
   ```sql
   CREATE SECRET s3_secret (TYPE s3, PROVIDER credential_chain, REGION 'eu-west-2');
   ```
5. For the pins R package, ensure `board_s3()` picks up credentials from the environment rather than hardcoded values.

**Warning signs:**
- AWS access keys appear in any `.r`, `.py`, or `.sql` file.
- Multiple team members share the same `AWS_ACCESS_KEY_ID`.
- Credentials appear in git history.

**Phase to address:**
Phase 0 (Infrastructure/Auth Setup) -- must be resolved before any S3 interaction code is written.

---

### Pitfall 6: pins R and Python Implementations Have Different Semantics and Versioning Behaviour

**What goes wrong:**
The R `pins` package and Python `pins` package are separate implementations with subtly different behaviour. Pin naming conventions, versioning strategies, and metadata formats differ. A pin written by R may not be straightforwardly readable by Python's `pins` (or vice versa), particularly for non-trivial types like Parquet with spatial data. The R package uses `board_s3()` while Python uses `board_s3()` with different underlying S3 client libraries (R uses `paws` or `aws.s3`, Python uses `boto3`).

**Why it happens:**
The pins packages were developed as separate implementations sharing a specification. Version compatibility has improved over time but edge cases remain, especially around metadata format versions and type handling.

**How to avoid:**
1. Decide on a single "writer" language for each pin. Either R writes and both read, or Python writes and both read. Do not have both languages writing to the same pin name.
2. Test cross-language reading early with a representative sample (including the spatial WKB column and large tables).
3. Pin type should be `"parquet"` (not `"arrow"` or `"rds"`) for cross-language compatibility.
4. Standardise on the same pins metadata version. Check `pin_meta()` in R and `board.pin_meta()` in Python to verify version compatibility.
5. Consider whether pins is the right abstraction at all for DuckLake -- DuckLake itself provides versioned, discoverable tables that both R and Python can query via DuckDB. Pins may be redundant once DuckLake is operational.

**Warning signs:**
- `pin_read()` in one language fails on pins written by the other language.
- Metadata (title, description) set in one language does not appear in the other.
- Pin versions diverge between languages.

**Phase to address:**
Phase 1 (Pins/S3 Setup) -- validate cross-language compatibility before building the full pipeline.

---

## Technical Debt Patterns

Shortcuts that seem reasonable but create long-term problems.

| Shortcut | Immediate Benefit | Long-term Cost | When Acceptable |
|----------|-------------------|----------------|-----------------|
| Export all tables as flat Parquet without partitioning | Simple export script | 19M-row table is slow to query from S3; full table scan required | Only for tables under 1M rows |
| Use DuckDB file as DuckLake metadata catalogue | No external database dependency | Single-writer limitation; no concurrent team access without file sharing | Development/prototyping only |
| Skip metadata/comment migration | Faster initial export | Team loses institutional knowledge about column meanings | Never -- the README states metadata is a core asset |
| Store all 18 tables as individual pins | Maps 1:1 to source tables | Pins not designed for 18+ related tables; no relational querying; no joins | Only for the simpler tables consumers need independently |
| Use a single S3 bucket for everything | Simple setup | No separation between DuckLake data files, pin artefacts, and backups; hard to set granular IAM policies | Never once team access is involved |

## Integration Gotchas

Common mistakes when connecting to external services.

| Integration | Common Mistake | Correct Approach |
|-------------|----------------|------------------|
| DuckDB + S3 | Forgetting to set `REGION` in the S3 secret; defaults to `us-east-1` which fails for `eu-west-2` buckets | Always specify `REGION 'eu-west-2'` explicitly in `CREATE SECRET` |
| DuckLake + PostgreSQL catalogue | Using DuckDB file as catalogue for team access; only one writer can connect at a time | Use PostgreSQL as the metadata catalogue for concurrent multi-user access |
| DuckLake + S3 data path | Omitting trailing `/` in `DATA_PATH`; DuckLake requires it | Always end S3 paths with `/`: `DATA_PATH 's3://bucket/prefix/'` |
| pins + S3 | Assuming pins handles S3 authentication automatically | Ensure AWS credentials are available in the environment before creating the board |
| DuckLake ATTACH | Using the in-memory database by accident (forgetting to `USE ducklake_catalog`) | Always `USE` the DuckLake catalogue immediately after `ATTACH`, or qualify all table names |
| DuckDB spatial + Parquet | Exporting without loading the `spatial` extension; geometry columns become raw blobs | Always `INSTALL spatial; LOAD spatial;` before any spatial export operation |
| DuckLake migration script | Assuming the migration script handles S3 targets | The official migration script currently only supports local migrations; S3 migration requires manual adaptation |

## Performance Traps

Patterns that work at small scale but fail as usage grows.

| Trap | Symptoms | Prevention | When It Breaks |
|------|----------|------------|----------------|
| Single large Parquet file per table | Slow S3 reads; high latency for simple queries | Use `per_thread_output` in DuckLake or partition large exports | Tables over 1M rows or 500 MB |
| No row group tuning | Full file scan even for filtered queries | Set `parquet_row_group_size` to 100K-200K rows; enables predicate pushdown | Tables over 5M rows |
| No partitioning on large tables | Every query reads all data files | Partition EPC table by region or date; DuckLake supports partitioning with transforms | 19M rows with frequent filtered access |
| Skipping `merge_adjacent_files` after incremental inserts | Hundreds of tiny Parquet files accumulate; query planning overhead | Schedule periodic `CHECKPOINT` or `merge_adjacent_files` calls | After 50+ incremental inserts |
| Reading DuckLake tables via pins instead of DuckDB | Double serialisation (DuckLake -> Parquet pin -> read); no predicate pushdown | Have R/Python consumers query DuckLake directly via DuckDB | When query patterns involve filtering or joining |

## Security Mistakes

Domain-specific security issues beyond general web security.

| Mistake | Risk | Prevention |
|---------|------|------------|
| Committing AWS credentials in `.r` or `.py` scripts | Full S3 bucket access compromise | Use `credential_chain` provider; add `.env` to `.gitignore`; enable pre-commit secret scanning |
| Giving all team members S3 write + delete permissions | Accidental or malicious data deletion | Separate IAM roles: superuser, writer, reader (as per DuckLake access control docs) |
| Using DuckDB file catalogue on a shared drive | No authentication; anyone with file access can modify metadata | Use PostgreSQL with per-user credentials for the DuckLake metadata catalogue |
| S3 bucket with public read access | Data exposure (EPC data contains addresses) | Ensure bucket policy blocks public access; use `s3:GetObject` only for authenticated principals |
| Not encrypting Parquet files on S3 | Data at rest unprotected | Enable S3 server-side encryption (SSE-S3 or SSE-KMS); DuckLake also supports file-level encryption via `encrypted` metadata option |

## UX Pitfalls

Common user experience mistakes in this domain.

| Pitfall | User Impact | Better Approach |
|---------|-------------|-----------------|
| No data catalogue or discoverability layer | Team members do not know what tables/pins exist or what columns mean | Use DuckLake's `COMMENT ON` and tags for table/column descriptions; publish a data dictionary |
| Requiring DuckDB installation to access any data | Non-technical users cannot access data | Provide pins as a simpler access path for basic consumers; reserve DuckLake for power users |
| No versioning strategy for data refreshes | Users do not know if they have the latest data | Use DuckLake snapshots for versioned access; use pin versioning for the pins pathway |
| Exposing raw column names from EPC data | Column names like `CURRENT_ENERGY_RATING` are cryptic without context | Add column comments and consider publishing a view layer with friendlier names |

## "Looks Done But Isn't" Checklist

Things that appear complete but are missing critical pieces.

- [ ] **Parquet export:** Often missing spatial metadata -- verify geometry columns are queryable as spatial objects in R (`sf::st_read()`) and Python (`geopandas.read_parquet()`)
- [ ] **DuckLake migration:** Often missing column comments -- verify with `SELECT comment FROM duckdb_columns() WHERE database_name = 'ducklake_catalog'`
- [ ] **S3 permissions:** Often missing `s3:ListBucket` for readers -- without it, `GetObject` fails with misleading "Access Denied" on missing keys rather than 404
- [ ] **pins setup:** Often missing cross-language validation -- verify a pin written in Python can be read in R and vice versa
- [ ] **DuckLake maintenance:** Often missing scheduled compaction -- verify `CHECKPOINT` or `merge_adjacent_files` runs after bulk inserts
- [ ] **Data refresh pipeline:** Often missing deduplication logic -- verify row counts match expected values after each refresh cycle (especially without primary keys)
- [ ] **Large table export:** Often missing multipart upload configuration -- verify boto3 `TransferConfig` is set for files over 100 MB
- [ ] **DuckLake ATTACH:** Often missing explicit `DATA_PATH` for S3 -- the default is `<metadata_file>.files` which only works for local storage

## Recovery Strategies

When pitfalls occur despite prevention, how to recover.

| Pitfall | Recovery Cost | Recovery Steps |
|---------|---------------|----------------|
| WKB_BLOB exported as raw binary | MEDIUM | Re-export with `ST_GeomFromWKB()` conversion; update all downstream pins |
| Comments/metadata lost in migration | LOW | Re-extract from source DuckDB using `duckdb_columns()`; re-apply with `COMMENT ON` |
| Duplicate rows from missing upsert logic | MEDIUM | Deduplicate with `CREATE TABLE AS SELECT DISTINCT ...`; rewrite refresh logic with `MERGE INTO` |
| OOM on large table export | LOW | Restart with partitioned export or `per_thread_output`; no data loss |
| Credentials committed to git | HIGH | Rotate all AWS keys immediately; use `git filter-branch` or `bfg` to remove from history; enable credential scanning |
| Tiny Parquet files accumulated | LOW | Run `CALL ducklake_merge_adjacent_files('catalog')` followed by cleanup |
| pins cross-language incompatibility | MEDIUM | Standardise on single writer language; re-write affected pins; test with both languages before proceeding |

## Pitfall-to-Phase Mapping

How roadmap phases should address these pitfalls.

| Pitfall | Prevention Phase | Verification |
|---------|------------------|--------------|
| WKB_BLOB geometry degradation | Phase 1: Data Export | `typeof(geom_col)` returns `GEOMETRY` not `BLOB`; downstream spatial read succeeds |
| Metadata/comments loss | Phase 1: Data Export | `COMMENT ON` values present after migration; companion metadata files exist for pins |
| No primary keys in DuckLake | Phase 2: DuckLake Setup | `MERGE INTO` patterns documented and tested; deduplication checks in place |
| Large table OOM/timeout | Phase 1: Data Export | 19M-row table exports in under 10 minutes; produces multiple files under 500 MB each |
| AWS credential management | Phase 0: Infrastructure | `credential_chain` provider used; no static keys in code; per-user IAM roles created |
| pins R/Python incompatibility | Phase 1: Pins Setup | Cross-language read test passes for all pin types including spatial |
| Missing compaction schedule | Phase 3: Maintenance | `CHECKPOINT` or equivalent runs after each refresh cycle; file count stays reasonable |
| DuckLake access control gaps | Phase 2: DuckLake Setup | Reader/writer/superuser roles tested; S3 policies scoped to appropriate prefixes |
| DuckLake unsupported features | Phase 2: DuckLake Setup | Source DB audited for ENUMs, UDTs, sequences, indexes; migration plan for each |

## Sources

- DuckLake specification v0.3 and DuckDB extension documentation: `docs/ducklake-docs.md` (local, verified directly) -- HIGH confidence
- DuckLake geometry type support: spec section "Geometry Types" -- HIGH confidence
- DuckLake unsupported features list: spec section "Unsupported Features" -- HIGH confidence
- DuckLake access control with S3 and PostgreSQL: spec section "Access Control" -- HIGH confidence
- DuckLake maintenance (compaction, expiry, cleanup): spec sections on `merge_adjacent_files`, `expire_snapshots`, `cleanup_old_files` -- HIGH confidence
- DuckLake comments support: spec section "Comments" -- HIGH confidence
- DuckLake migration script limitations (local only): spec note "Currently, only local migrations are supported by this script" -- HIGH confidence
- pins R/Python cross-language behaviour: training data only -- LOW confidence (needs validation with actual testing)
- DuckDB spatial extension WKB handling: training data -- MEDIUM confidence (well-established pattern but not verified against current version)
- S3 multipart upload limits: training data -- HIGH confidence (fundamental AWS constraint, stable)
- Large Parquet file performance characteristics: training data -- MEDIUM confidence (general industry knowledge)

---
*Pitfalls research for: DuckDB-to-S3 data sharing platform (DuckLake + pins)*
*Researched: 2026-02-22*
