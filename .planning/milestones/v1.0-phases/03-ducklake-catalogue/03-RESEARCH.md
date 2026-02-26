# Phase 3: DuckLake Catalogue - Research

**Researched:** 2026-02-23
**Domain:** DuckLake extension for DuckDB -- catalogue creation, metadata, time travel, views
**Confidence:** HIGH

## Summary

DuckLake is a DuckDB extension (v0.3, requires DuckDB >= 1.3.0) that stores metadata in a SQL catalogue database and data as Parquet files on object storage. The extension provides `ATTACH`, `COMMENT ON`, `CREATE VIEW`, time travel (`AT VERSION/TIMESTAMP`), data change feed (`table_changes()`), and maintenance operations (`CHECKPOINT`, `ducklake_expire_snapshots`).

The migration path from an existing DuckDB file to DuckLake is straightforward: `COPY FROM DATABASE` copies tables, views, and (with DuckDB as catalogue backend) macros. However, several existing views in the source database reference spatial functions (`st_transform`, `geopoint_from_blob`) and spatial tables, so these views cannot be migrated in Phase 3 -- they must be deferred to Phase 4 or recreated without spatial joins.

**Primary recommendation:** Use a DuckDB file on S3 as the catalogue database (simplest for single-analyst use), with `DATA_PATH` pointing to `s3://stevecrawshaw-bucket/ducklake/data/`. Register non-spatial tables via `COPY FROM DATABASE`, register spatial tables as empty shells (schema only), apply comments programmatically, create views manually, and configure snapshot retention.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `ducklake` | 0.3 | DuckDB extension for DuckLake catalogue | Only implementation of DuckLake specification |
| DuckDB | >= 1.3.0 (latest stable) | Query engine | Required by ducklake extension |
| `httpfs` | (bundled) | S3 access from DuckDB | Required for S3 DATA_PATH and remote catalogue file |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `aws` | (bundled) | AWS credential chain | Automatic credential resolution for S3 |
| `spatial` | (bundled) | Geometry support | Phase 4 (spatial tables), but needed for some source views |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| DuckDB catalogue on S3 | PostgreSQL on RDS | Multi-user concurrent writes, but adds infrastructure cost and complexity for a single-analyst use case |
| DuckDB catalogue on S3 | SQLite catalogue | Multi-client local access, but no advantage over DuckDB for remote/S3 deployment |
| `COPY FROM DATABASE` | Manual `CREATE TABLE AS` | More control per table, but slower and more error-prone |

## Architecture Patterns

### Recommended Catalogue Layout
```
s3://stevecrawshaw-bucket/
  ducklake/
    mca_env.ducklake          # DuckLake catalogue database (DuckDB file)
    data/                     # Parquet data files (auto-managed by DuckLake)
      <table_name>/
        data_0.parquet
        ...
  pins/                       # Existing pins from Phase 2 (separate concern)
```

### Pattern 1: Catalogue Creation and Table Registration
**What:** Attach source DuckDB read-only, create DuckLake, copy tables across
**When to use:** Initial catalogue setup
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/migrations/duckdb_to_ducklake
INSTALL ducklake;
LOAD ducklake;

-- Create S3 secret for data access
CREATE SECRET s3_secret (
    TYPE s3,
    KEY_ID '...',
    SECRET '...',
    REGION 'eu-west-2'
);

-- Create the DuckLake catalogue
ATTACH 'ducklake:s3://stevecrawshaw-bucket/ducklake/mca_env.ducklake'
    AS lake (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

-- Attach source database
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);

-- Copy all tables (including spatial -- geometry columns stored as-is)
COPY FROM DATABASE source TO lake;
```

### Pattern 2: Selective Table Registration (if COPY FROM DATABASE has issues)
**What:** Create tables individually from source, useful when COPY FROM DATABASE fails on unsupported types
**When to use:** Fallback if bulk copy hits spatial type issues
**Example:**
```sql
CREATE TABLE lake.boundary_lookup_tbl AS
    SELECT * FROM source.boundary_lookup_tbl;
```

### Pattern 3: Metadata Comments Application
**What:** Apply COMMENT ON statements for tables and columns from source metadata
**When to use:** After table registration
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/advanced_features/comments
COMMENT ON TABLE lake.boundary_lookup_tbl IS 'Boundary lookup table';
COMMENT ON COLUMN lake.boundary_lookup_tbl.ladcd IS 'Local Authority District code';
```

### Pattern 4: View Creation
**What:** Create views in the DuckLake catalogue
**When to use:** After all referenced tables exist
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/advanced_features/views
CREATE VIEW lake.la_ghg_emissions_weca_vw AS
    SELECT * FROM lake.la_ghg_emissions_tbl
    WHERE local_authority_code IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');
```

### Pattern 5: Time Travel Query
**What:** Query a table at a historical snapshot
**When to use:** Analyst wants to see data as it was before a refresh
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/usage/time_travel
SELECT * FROM lake.la_ghg_emissions_tbl AT (VERSION => 1);
SELECT * FROM lake.la_ghg_emissions_tbl AT (TIMESTAMP => now() - INTERVAL '1 week');
```

### Pattern 6: Data Change Feed
**What:** See what changed between snapshots
**When to use:** Analyst wants to audit data refreshes
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/advanced_features/data_change_feed
SELECT * FROM lake.table_changes('la_ghg_emissions_tbl', 1, 2);
SELECT * FROM lake.table_changes('la_ghg_emissions_tbl', now() - INTERVAL '1 week', now());
```

### Pattern 7: Snapshot Management and Maintenance
**What:** List snapshots, expire old ones, run maintenance
**When to use:** Periodic maintenance
**Example:**
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/usage/snapshots
-- List all snapshots
SELECT * FROM lake.snapshots();

-- Set retention policy
CALL lake.set_option('expire_older_than', '30 days');

-- Expire specific snapshots
CALL ducklake_expire_snapshots('lake', older_than => now() - INTERVAL '30 days');

-- Or run all maintenance at once
CHECKPOINT lake;
```

### Anti-Patterns to Avoid
- **Storing catalogue DB locally while data is on S3:** Analysts cannot access the catalogue unless it is also shared. Put the .ducklake file on S3 or in a shared database.
- **Migrating spatial views in Phase 3:** Views like `ca_boundaries_inc_ns_vw` and `epc_domestic_lep_vw` depend on spatial functions (`st_transform`, `geopoint_from_blob`) and spatial table joins. These must wait for Phase 4.
- **Using MySQL as catalogue backend:** Known issues documented by DuckLake team; not recommended.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Table migration | Manual CREATE TABLE + INSERT loops | `COPY FROM DATABASE` | Handles all tables, types, and dependencies automatically |
| Snapshot management | Custom version tracking | DuckLake `snapshots()` + `AT (VERSION)` | Built-in, transactional, zero overhead |
| Data change auditing | Diff queries comparing snapshots manually | `table_changes()` function | Returns insert/delete/update with pre/post images |
| File compaction | Manual parquet file management | `CHECKPOINT` | Runs all maintenance ops in correct order |
| Comment migration | Manual typing of descriptions | Scripted extraction from `duckdb_columns()` + `COMMENT ON` | Source has 400+ column comments; must be automated |

**Key insight:** DuckLake provides time travel, change feed, and maintenance as built-in features. The implementation work is catalogue setup, comment migration, and view creation -- not building infrastructure.

## Common Pitfalls

### Pitfall 1: COPY FROM DATABASE and Spatial Views
**What goes wrong:** `COPY FROM DATABASE` will attempt to copy all views. Views that reference spatial functions (`st_transform`, `geopoint_from_blob`) or cross-database joins will fail.
**Why it happens:** The source database has 7 views; 4 of them reference spatial tables or spatial functions.
**How to avoid:** Either (a) copy tables only and create views manually, or (b) use `COPY FROM DATABASE` and handle errors for spatial views gracefully. Safest approach: create tables via COPY, then create views manually.
**Warning signs:** Error messages mentioning `st_transform`, `geopoint_from_blob`, or missing spatial extension.

### Pitfall 2: DuckDB Catalogue File on S3 -- Single Client Limitation
**What goes wrong:** DuckDB as catalogue backend only supports a single client. Two analysts running ATTACH simultaneously on the same S3 .ducklake file will conflict.
**Why it happens:** DuckDB uses file-level locking not compatible with S3's eventual consistency.
**How to avoid:** For Phase 3 (single analyst), this is acceptable. Document the limitation. If multi-user is needed later, migrate catalogue to PostgreSQL.
**Warning signs:** Lock errors or corrupted catalogue on concurrent access.

### Pitfall 3: DATA_PATH Must Already Exist
**What goes wrong:** ATTACH with a new DATA_PATH fails if the S3 prefix doesn't have any objects.
**Why it happens:** DuckLake checks for the data directory existence.
**How to avoid:** Create a placeholder object in `s3://stevecrawshaw-bucket/ducklake/data/` before first ATTACH, or ensure the path exists.
**Warning signs:** Error on first ATTACH about directory not found.

### Pitfall 4: Comment Migration Volume
**What goes wrong:** Manually writing COMMENT ON statements for 400+ columns is error-prone and tedious.
**Why it happens:** 18 tables with varying column counts (3 to 93 columns each), most with existing comments.
**How to avoid:** Script the comment extraction from `duckdb_columns()` and `duckdb_tables()` and generate COMMENT ON statements programmatically.
**Warning signs:** Missing comments, typos in descriptions.

### Pitfall 5: View Dependencies on Spatial Tables
**What goes wrong:** Some source views (`epc_domestic_lep_vw`, `epc_non_domestic_lep_vw`, `ca_boundaries_inc_ns_vw`) JOIN with spatial tables. These views cannot exist in DuckLake until the spatial tables are registered with correct geometry columns.
**Why it happens:** Phase 3 registers spatial tables but may not handle geometry column conversion.
**How to avoid:** Only create views that reference non-spatial tables or only non-spatial columns. Defer spatial-dependent views to Phase 4.
**Warning signs:** View creation errors referencing missing columns or tables.

### Pitfall 6: DuckLake Does Not Support Constraints
**What goes wrong:** Attempting to create PRIMARY KEY, FOREIGN KEY, UNIQUE, or CHECK constraints fails.
**Why it happens:** DuckLake specification does not support indexes or constraints.
**How to avoid:** Accept this limitation. The source DuckDB likely has no constraints either (common for analytical warehouses).
**Warning signs:** Constraint-related errors during COPY FROM DATABASE (unlikely for this dataset).

## Code Examples

### Complete Catalogue Setup Script (R or DuckDB CLI)
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/introduction
-- Source: https://ducklake.select/docs/stable/duckdb/migrations/duckdb_to_ducklake

-- Step 1: Install and load extensions
INSTALL ducklake;
LOAD ducklake;
INSTALL httpfs;
LOAD httpfs;

-- Step 2: Configure S3 credentials
CREATE SECRET (
    TYPE s3,
    KEY_ID '${AWS_ACCESS_KEY_ID}',
    SECRET '${AWS_SECRET_ACCESS_KEY}',
    REGION 'eu-west-2'
);

-- Step 3: Create DuckLake catalogue on S3
ATTACH 'ducklake:s3://stevecrawshaw-bucket/ducklake/mca_env.ducklake'
    AS lake (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

-- Step 4: Attach source database
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);

-- Step 5: Copy all tables from source to lake
COPY FROM DATABASE source TO lake;

-- Step 6: Apply table comments
COMMENT ON TABLE lake.boundary_lookup_tbl IS 'Boundary lookup table';
-- ... (generated programmatically from source metadata)

-- Step 7: Apply column comments
COMMENT ON COLUMN lake.boundary_lookup_tbl.ladcd IS 'Local Authority District code';
-- ... (generated programmatically from source metadata)

-- Step 8: Create views (non-spatial only in Phase 3)
CREATE VIEW lake.ca_la_lookup_inc_ns_vw AS (
    SELECT LAD25CD AS ladcd, LAD25NM AS ladnm, CAUTH25CD AS cauthcd, CAUTH25NM AS cauthnm
    FROM lake.ca_la_lookup_tbl
) UNION BY NAME (
    SELECT 'E06000024' AS ladcd, 'North Somerset' AS ladnm,
           'E47000009' AS cauthcd, 'West of England' AS cauthnm
);

CREATE VIEW lake.weca_lep_la_vw AS
    SELECT * FROM lake.ca_la_lookup_inc_ns_vw WHERE cauthnm = 'West of England';

-- Step 9: Create WECA-filtered views
CREATE VIEW lake.la_ghg_emissions_weca_vw AS
    SELECT * FROM lake.la_ghg_emissions_tbl
    WHERE local_authority_code IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

-- Step 10: Configure snapshot retention
CALL lake.set_option('expire_older_than', '90 days');

-- Step 11: Verify
SELECT * FROM lake.snapshots();
```

### Analyst Connection Script
```sql
-- Source: https://ducklake.select/docs/stable/duckdb/usage/connecting
INSTALL ducklake;
LOAD ducklake;

-- Create or load S3 credentials
CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);

-- Attach the shared catalogue (read-only for analysts)
ATTACH 'ducklake:s3://stevecrawshaw-bucket/ducklake/mca_env.ducklake' AS lake (READ_ONLY);
USE lake;

-- Query tables
SELECT * FROM la_ghg_emissions_tbl LIMIT 10;

-- Time travel
SELECT * FROM la_ghg_emissions_tbl AT (VERSION => 1);

-- View available snapshots
SELECT * FROM lake.snapshots();
```

### Programmatic Comment Generation (Python)
```python
import duckdb

source = duckdb.connect('data/mca_env_base.duckdb', read_only=True)

# Extract table comments
tables = source.execute("""
    SELECT table_name, comment
    FROM duckdb_tables()
    WHERE schema_name = 'main' AND NOT internal AND comment IS NOT NULL
""").fetchall()

# Extract column comments
columns = source.execute("""
    SELECT table_name, column_name, comment
    FROM duckdb_columns()
    WHERE schema_name = 'main' AND comment IS NOT NULL AND comment != ''
""").fetchall()

# Generate SQL
for tbl, comment in tables:
    comment_escaped = comment.replace("'", "''")
    print(f"COMMENT ON TABLE lake.{tbl} IS '{comment_escaped}';")

for tbl, col, comment in columns:
    comment_escaped = comment.replace("'", "''")
    print(f"COMMENT ON COLUMN lake.{tbl}.{col} IS '{comment_escaped}';")
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| DuckLake 0.1 (no geometry) | DuckLake 0.3 (geometry + Iceberg interop) | Sep 2025 | Spatial tables can be registered directly |
| Manual file management | `CHECKPOINT` for all maintenance | DuckLake 0.3 | Single command runs expire + merge + cleanup |
| No data change feed | `table_changes()` function | DuckLake 0.1 | Analysts can audit data refreshes |

**Deprecated/outdated:**
- DuckLake 0.1/0.2: superseded by 0.3 which adds geometry support and CHECKPOINT

## Source Database Analysis

### Tables by Category
| Category | Count | Tables |
|----------|-------|--------|
| Non-spatial | 10 | boundary_lookup_tbl, ca_la_lookup_tbl, eng_lsoa_imd_tbl, iod2025_tbl, la_ghg_emissions_tbl, la_ghg_emissions_wide_tbl, postcode_centroids_tbl, raw_domestic_epc_certificates_tbl, raw_non_domestic_epc_certificates_tbl, uk_lsoa_tenure_tbl |
| Spatial | 8 | bdline_ua_lep_diss_tbl, bdline_ua_lep_tbl, bdline_ua_weca_diss_tbl, bdline_ward_lep_tbl, ca_boundaries_bgc_tbl, codepoint_open_lep_tbl, lsoa_2021_lep_tbl, open_uprn_lep_tbl |

### Existing Views -- Migration Feasibility
| View | Depends on Spatial? | Phase 3 Feasible? | Notes |
|------|---------------------|-------------------|-------|
| `ca_la_lookup_inc_ns_vw` | No | Yes | UNION with literal values, references ca_la_lookup_tbl only |
| `weca_lep_la_vw` | No | Yes | Simple filter on ca_la_lookup_inc_ns_vw |
| `ca_la_ghg_emissions_sub_sector_ods_vw` | No (via view) | Yes | JOIN la_ghg_emissions_tbl with ca_la_lookup_inc_ns_vw |
| `epc_domestic_vw` | No | Yes | Computed columns from raw_domestic_epc_certificates_tbl |
| `ca_boundaries_inc_ns_vw` | Yes (st_transform, bdline_ua_lep_diss_tbl, ca_boundaries_bgc_tbl) | No -- defer to Phase 4 |
| `epc_domestic_lep_vw` | Yes (geopoint_from_blob, open_uprn_lep_tbl) | No -- defer to Phase 4 |
| `epc_non_domestic_lep_vw` | Yes (geopoint_from_blob, open_uprn_lep_tbl) | No -- defer to Phase 4 |

### WECA LA Codes
| Code | Authority |
|------|-----------|
| E06000022 | Bath and North East Somerset |
| E06000023 | Bristol, City of |
| E06000024 | North Somerset |
| E06000025 | South Gloucestershire |

### Tables Eligible for WECA-Filtered Views
| Table | Filter Column | Column Name |
|-------|---------------|-------------|
| la_ghg_emissions_tbl | LA code | `local_authority_code` |
| la_ghg_emissions_wide_tbl | LA code | `local_authority_code` |
| raw_domestic_epc_certificates_tbl | LA code | `LOCAL_AUTHORITY` |
| raw_non_domestic_epc_certificates_tbl | LA code | `LOCAL_AUTHORITY` |
| boundary_lookup_tbl | LA code | `ladcd` |
| postcode_centroids_tbl | LA code | `lad25cd` |
| iod2025_tbl | LA code | `la_cd` |
| ca_la_lookup_tbl | LA code | `LAD25CD` |
| codepoint_open_lep_tbl | District code | `admin_district_code` (but this is a spatial table) |

### Comment Coverage in Source
- All 18 tables have table-level comments (though 3 are auto-generated like "Table containing 56 columns")
- Most tables have 100% column comment coverage
- Exceptions: postcode_centroids_tbl (55/60), uk_lsoa_tenure_tbl (3/5)
- Total: ~400+ column comments to migrate

## Open Questions

1. **Can the DuckDB .ducklake file be stored on S3?**
   - What we know: Official docs show local file paths for DuckDB backend. S3 examples use PostgreSQL as catalogue backend. DuckDB supports reading/writing files on S3 via httpfs.
   - What's unclear: Whether ATTACH with a `ducklake:s3://...` path for the catalogue file itself works reliably. DuckDB file locking on S3 may be problematic.
   - Recommendation: Test this first. If it fails, use a local .ducklake file and share it via S3 copy, or switch to SQLite/PostgreSQL. **HIGH PRIORITY to validate.**

2. **Does COPY FROM DATABASE copy comments?**
   - What we know: Documentation says it copies tables and views. Comments are stored in DuckLake's `ducklake_tag` and `ducklake_column_tag` tables.
   - What's unclear: Whether `COPY FROM DATABASE` also migrates DuckDB comments into DuckLake tag tables.
   - Recommendation: Test. If not, apply comments programmatically (code example provided). **MEDIUM PRIORITY.**

3. **Does COPY FROM DATABASE handle WKB_BLOB/GEOMETRY columns?**
   - What we know: DuckLake 0.3 supports geometry types. COPY FROM DATABASE may need type casting for unsupported types.
   - What's unclear: Whether WKB_BLOB (a BLOB alias) and GEOMETRY columns copy without errors.
   - Recommendation: Try COPY FROM DATABASE for all 18 tables. If spatial types fail, copy non-spatial tables via COPY FROM DATABASE and register spatial tables individually in Phase 4. **HIGH PRIORITY to validate.**

4. **Snapshot Retention: "Last 5 versions" vs "older_than interval"**
   - What we know: DuckLake's `ducklake_expire_snapshots` supports `older_than` (time-based) and `versions` (specific IDs). The `set_option('expire_older_than', ...)` sets a global time threshold.
   - What's unclear: Whether there's a native "keep last N snapshots" option. The user decision says "last 5 versions per table" but DuckLake snapshots are database-level, not per-table.
   - Recommendation: Use time-based retention (e.g., `expire_older_than => '90 days'`) as DuckLake snapshots are database-wide, not per-table. Document this deviation from the "last 5" request.

## Sources

### Primary (HIGH confidence)
- Context7 `/websites/ducklake_select_stable` -- ATTACH, COMMENT ON, time travel, data change feed, views
- [DuckLake Introduction](https://ducklake.select/docs/stable/duckdb/introduction) -- ATTACH syntax, DATA_PATH, basic usage
- [DuckLake Connecting](https://ducklake.select/docs/stable/duckdb/usage/connecting) -- Connection strings, secrets, S3 paths
- [DuckLake Choosing Catalogue Database](https://ducklake.select/docs/stable/duckdb/usage/choosing_a_catalog_database) -- DuckDB vs PostgreSQL vs SQLite vs MySQL
- [DuckLake Time Travel](https://ducklake.select/docs/stable/duckdb/usage/time_travel) -- AT VERSION, AT TIMESTAMP, snapshot attachment
- [DuckLake Data Change Feed](https://ducklake.select/docs/stable/duckdb/advanced_features/data_change_feed) -- table_changes() function
- [DuckLake Comments](https://ducklake.select/docs/stable/duckdb/advanced_features/comments) -- COMMENT ON syntax, storage in ducklake_tag tables
- [DuckLake Views](https://ducklake.select/docs/stable/duckdb/advanced_features/views) -- CREATE VIEW support
- [DuckLake Snapshots](https://ducklake.select/docs/stable/duckdb/usage/snapshots) -- snapshots() function, metadata columns
- [DuckLake Expire Snapshots](https://ducklake.select/docs/stable/duckdb/maintenance/expire_snapshots) -- Retention policy, expire_older_than
- [DuckLake Recommended Maintenance](https://ducklake.select/docs/stable/duckdb/maintenance/recommended_maintenance) -- CHECKPOINT, file merging
- [DuckDB to DuckLake Migration](https://ducklake.select/docs/stable/duckdb/migrations/duckdb_to_ducklake) -- COPY FROM DATABASE syntax and limitations
- [DuckLake FAQ](https://ducklake.select/faq) -- Architecture, catalogue options

### Secondary (MEDIUM confidence)
- [DuckLake 0.3 Release](https://ducklake.select/2025/09/17/ducklake-03/) -- Geometry support, CHECKPOINT, Iceberg interop
- [MotherDuck DuckDB 1.4.1 + DuckLake 0.3](https://motherduck.com/blog/announcing-duckdb-141-motherduck/) -- Version compatibility
- [DuckDB COMMENT ON](https://duckdb.org/docs/stable/sql/statements/comment_on) -- Standard DuckDB comment syntax

### Tertiary (LOW confidence)
- None -- all findings verified against official documentation

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH -- verified against Context7 and official DuckLake docs
- Architecture: HIGH -- patterns taken directly from official migration guide and usage docs
- Pitfalls: HIGH for documented ones, MEDIUM for S3 catalogue file behaviour (needs validation)

**Research date:** 2026-02-23
**Valid until:** 2026-03-23 (DuckLake 0.3 is stable; no major releases imminent)
