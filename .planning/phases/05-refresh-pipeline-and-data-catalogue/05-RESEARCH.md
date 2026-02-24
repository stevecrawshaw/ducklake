# Phase 5: Refresh Pipeline and Data Catalogue - Research

**Researched:** 2026-02-24
**Domain:** R-based data pipeline orchestration + DuckLake/pins metadata cataloguing
**Confidence:** HIGH

## Summary

Phase 5 combines two related concerns: (1) a single R script that re-exports all 18 tables from the source DuckDB to both DuckLake and S3 pins, and (2) a queryable data catalogue built from DuckLake metadata. The existing codebase already contains all the building blocks -- `export_pins.R` handles non-spatial parquet exports, `export_spatial_pins.R` handles GeoParquet exports, `create_ducklake.sql` handles DuckLake table creation, and `recreate_spatial_ducklake.sql` handles spatial table recreation. The refresh script consolidates these into a single orchestrated pass.

The catalogue is built from DuckLake's `information_schema`, `duckdb_tables()`, and `duckdb_columns()` functions, which already expose table names, column types, and comments. The main new work is: (a) sampling example values per column, (b) extracting spatial metadata (geometry type, CRS, bounding box) for spatial tables, and (c) exposing the catalogue as both DuckLake views and pinned parquet files.

**Primary recommendation:** Build `scripts/refresh.R` as a single-pass orchestrator that iterates all 18 tables, detects spatial vs non-spatial, exports to both DuckLake (DROP + CREATE) and pins (pin_write/pin_upload), validates row counts, then generates and exports catalogue tables.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Always full refresh -- all 18 tables re-exported every run (no selective/incremental)
- Single R script entry point (e.g. `scripts/refresh.R`), consistent with existing `create_ducklake.R` pattern
- Unified single pass handling both non-spatial (parquet) and spatial (GeoParquet) tables -- script detects spatial columns and routes accordingly
- Data only -- do not re-apply column comments or recreate views (those are structural and rarely change)
- Drop and recreate DuckLake tables on each refresh -- DuckLake's 90-day retention policy preserves previous snapshots for time travel
- Pins: new version each time via `pin_write()` -- analysts get latest by default, can access history via `pin_versions()`
- Row count validation after each table export -- compare source vs destination counts
- Console summary table at end of run showing table name, row count, time taken, pass/fail
- DuckLake views (queryable via SQL) plus exported as pinned parquet files on S3 -- analysts can access either way
- Two normalised tables: `datasets_catalogue` (one row per table/view) and `columns_catalogue` (one row per column)
- Catalogue regenerated automatically at the end of every refresh run -- no separate step
- Include both base tables (18) and WECA-filtered views (12) -- a `type` column distinguishes tables from views
- Datasets catalogue: name, description, type (table/view), row count, last updated date, source table name (from mca_env_base.duckdb)
- Spatial tables additionally include: geometry type, CRS, bounding box
- Columns catalogue: table name, column name, data type, description, up to 3 distinct non-null example values (sampled from base tables)

### Claude's Discretion
- Internal structure of the refresh R script (function decomposition, error handling patterns)
- How to detect spatial vs non-spatial tables programmatically
- SQL implementation of catalogue views
- How to sample example values efficiently (LIMIT, USING SAMPLE, etc.)
- Console summary table formatting

### Deferred Ideas (OUT OF SCOPE)
None -- discussion stayed within phase scope
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|-----------------|
| REFRESH-01 | Script to re-export updated tables from source DuckDB to S3 | Existing `export_pins.R` + `export_spatial_pins.R` patterns; consolidated into single `refresh.R` with spatial detection |
| REFRESH-02 | Refresh preserves DuckLake history (snapshots retained for time travel) | DuckLake DROP TABLE + CREATE TABLE creates new snapshots; `expire_older_than` 90-day policy preserves history; confirmed via Context7 |
| REFRESH-03 | Refresh updates pins versions so analysts can see new data | `pin_write()` on versioned board automatically creates new version; `pin_upload()` likewise; confirmed via Context7 |
| CAT-01 | Queryable table-of-tables listing all available datasets with descriptions | DuckLake `duckdb_tables()` + `information_schema.tables` expose names, comments; catalogue views + pinned parquet |
| CAT-02 | Each dataset listing includes column names, types, and descriptions | DuckLake `duckdb_columns()` exposes column_name, data_type, comment; example values via `SELECT DISTINCT ... LIMIT 3` |
| CAT-03 | Each dataset listing includes row count and last updated date | Row count from `SELECT COUNT(*)`; last updated from `MAX(snapshot_timestamp)` in `ducklake_snapshot` or from current refresh timestamp |
</phase_requirements>

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| R (base) | 4.x | Script runtime | Project standard; all existing scripts are R |
| pins | 1.4+ | S3 pin versioning | Already used in export_pins.R and export_spatial_pins.R |
| duckdb (R) | 1.4.4 | Read source DuckDB | Used in export_pins.R for non-spatial table reads |
| DBI | 1.2+ | Database interface | Standard R database interface, already a dependency |
| arrow | 14+ | Parquet I/O | Already used for large table handling and validation |
| DuckDB CLI | 1.4.1+ | DuckLake operations | Required because R duckdb package lacks ducklake extension |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| sf | 1.0+ | Spatial metadata extraction | Bounding box calculation for spatial catalogue entries |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Single R script | Makefile/targets pipeline | Overkill for 18 tables; R script is simpler and consistent with existing patterns |
| DuckDB CLI for everything | R duckdb package for DuckLake | R duckdb v1.4.4 lacks ducklake extension; CLI is the established pattern |
| Separate catalogue script | Integrated catalogue generation | User decision: catalogue regenerated at end of every refresh run |

## Architecture Patterns

### Recommended Script Structure
```
scripts/
├── refresh.R                    # Single entry point (NEW)
├── create_ducklake.sql          # Reference only (not called by refresh)
├── recreate_spatial_ducklake.sql # Reference only (not called by refresh)
├── export_pins.R                # Reference only (not called by refresh)
├── export_spatial_pins.R        # Reference only (not called by refresh)
└── create_views.sql             # Reference only (views not recreated)
```

### Pattern 1: Unified Table Loop with Spatial Detection
**What:** Single loop over all 18 tables; detect spatial columns by checking for WKB_BLOB/GEOMETRY/BLOB column types; route to appropriate export logic.
**When to use:** Every refresh run.
**Example:**
```r
# Detect spatial tables by column type (established pattern from export_pins.R)
spatial_cols <- columns_df[
  grepl("BLOB|GEOMETRY|WKB", columns_df$data_type, ignore.case = TRUE),
]
spatial_tables <- unique(spatial_cols$table_name)
is_spatial <- tbl_name %in% spatial_tables
```
**Source:** `scripts/export_pins.R` lines 63-66

### Pattern 2: DuckDB CLI for DuckLake Operations
**What:** Build SQL strings in R, write to temp file, execute via `duckdb -init "file.sql" -c "SELECT 1;" -no-stdin`.
**When to use:** All DuckLake write operations (DROP TABLE, CREATE TABLE).
**Example:**
```r
# Established pattern from create_ducklake.R and export_spatial_pins.R
tmp_sql <- "scripts/.tmp_refresh.sql"
writeLines(sql_statements, tmp_sql, useBytes = TRUE)
cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql)
result <- system(cmd, intern = TRUE, timeout = 600)
file.remove(tmp_sql)
```
**Source:** `scripts/create_ducklake.R` lines 61-72

### Pattern 3: Dual Export (DuckLake + Pins) Per Table
**What:** For each table: (1) DROP + CREATE TABLE in DuckLake, (2) export as pin to S3. Both in the same loop iteration.
**When to use:** Every table in the refresh loop.
**Rationale:** Keeps DuckLake and pins in sync. If one fails, the error is reported per-table in the summary.

### Pattern 4: Chunked Pin Upload for Large Tables
**What:** Tables exceeding 5M rows use DuckDB `COPY TO` with LIMIT/OFFSET chunks, then `pin_upload()` instead of `pin_write()`.
**When to use:** `raw_domestic_epc_certificates_tbl` (19M+ rows).
**Source:** `scripts/export_pins.R` lines 122-156

### Pattern 5: Catalogue as DuckLake Views + Pinned Parquet
**What:** After all tables are refreshed, build two catalogue tables by querying DuckLake metadata, materialise as DuckLake tables (not views -- views cannot be pinned), and also export as pins.
**When to use:** End of every refresh run.
**Example SQL for datasets_catalogue:**
```sql
SELECT
  t.table_name AS name,
  COALESCE(t.comment, '') AS description,
  CASE WHEN it.table_type = 'VIEW' THEN 'view' ELSE 'table' END AS type,
  -- row_count filled programmatically
  -- last_updated filled from current refresh timestamp
FROM duckdb_tables() t
LEFT JOIN information_schema.tables it
  ON t.table_name = it.table_name
  AND it.table_catalog = 'lake'
WHERE t.database_name = 'lake'
ORDER BY t.table_name;
```

### Anti-Patterns to Avoid
- **Incremental refresh:** User explicitly chose full refresh every run. Do not add change detection.
- **Re-applying comments/views:** User decision: data only. Comments and views are structural and rarely change.
- **Separate catalogue step:** Catalogue must be generated as the final step of the same refresh script.
- **Using R duckdb package for DuckLake writes:** Will fail silently or with extension errors. Always use DuckDB CLI.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Spatial column detection | Custom heuristic per table name | `grepl("BLOB\|GEOMETRY\|WKB", data_type)` on duckdb_columns() | Established pattern from export_pins.R; works for all 8 spatial tables |
| Pin versioning | Manual S3 file management | `pin_write()` / `pin_upload()` with `versioned = TRUE` board | Pins handles version directories, metadata.json, cleanup |
| DuckLake time travel | Custom snapshot tracking | DuckLake's built-in `AT (VERSION => N)` with 90-day `expire_older_than` | Already configured in Phase 3 |
| Column metadata extraction | Manual SQL per table | `duckdb_columns()` system function | Returns column_name, data_type, comment in one query |
| GeoParquet writing | Custom parquet + geo metadata | DuckDB `COPY TO` with spatial extension | DuckDB automatically writes GeoParquet 1.0.0 metadata |

**Key insight:** Every component of the refresh pipeline already exists as a working script. The new work is consolidation and orchestration, not new capability.

## Common Pitfalls

### Pitfall 1: DuckLake DROP TABLE Does Not Delete S3 Data Files Immediately
**What goes wrong:** Dropping a DuckLake table marks the data files as candidates for deletion, but does not physically remove them from S3 until snapshot expiration + file cleanup runs.
**Why it happens:** DuckLake retains files for time travel. The 90-day `expire_older_than` policy governs when old snapshot data is physically removed.
**How to avoid:** This is the desired behaviour (REFRESH-02 requires preserved history). Do not run `ducklake_clean_files` after each refresh. Let the retention policy handle cleanup.
**Warning signs:** S3 storage growing after each refresh is expected and normal.
**Source:** [DuckLake maintenance docs](https://ducklake.select/docs/stable/duckdb/maintenance/recommended_maintenance)

### Pitfall 2: Spatial Table Geometry Conversion Edge Cases
**What goes wrong:** `ca_boundaries_bgc_tbl` has mixed POLYGON/MULTIPOLYGON (needs `ST_Multi()`), `lsoa_2021_lep_tbl` has 2 invalid geometries (needs `geom_valid` flag).
**Why it happens:** Source data quality issues; established in Phase 4 spike.
**How to avoid:** Carry forward the per-table edge case handling from `recreate_spatial_ducklake.sql` and `export_spatial_pins.R`.
**Warning signs:** Geometry type errors or silent data loss.
**Source:** `scripts/recreate_spatial_ducklake.sql`, Phase 4 findings

### Pitfall 3: curl 2GB Upload Limit for Large Pins
**What goes wrong:** `pin_write()` for tables with >2GB parquet output fails with `postfieldsize overflow`.
**Why it happens:** curl library limitation in R's HTTP stack.
**How to avoid:** Use chunked `COPY TO` with LIMIT/OFFSET + `pin_upload()` for tables exceeding 5M rows (the established pattern).
**Warning signs:** HTTP errors during pin upload of `raw_domestic_epc_certificates_tbl`.
**Source:** Phase 2 decision [02-02]

### Pitfall 4: DuckLake Catalogue File Requires S3 Data Path to Exist
**What goes wrong:** `ATTACH 'ducklake:data/mca_env.ducklake' AS lake (DATA_PATH 's3://...')` fails if the S3 prefix has no objects.
**Why it happens:** DuckLake validates the data path on attach.
**How to avoid:** The `.placeholder` file created in Phase 3 persists. Not an issue for refresh (data already exists). Only relevant for first-time setup.
**Warning signs:** S3 403 or "path does not exist" errors on attach.

### Pitfall 5: Example Value Sampling for Large Tables
**What goes wrong:** `SELECT DISTINCT col LIMIT 3` on a 19M-row table can be slow if the column has high cardinality.
**Why it happens:** DuckDB must scan potentially the entire column.
**How to avoid:** Use `USING SAMPLE 1000 ROWS` or `SELECT DISTINCT col FROM (SELECT col FROM tbl LIMIT 1000) LIMIT 3` to cap scan cost.
**Warning signs:** Catalogue generation taking minutes per column on large tables.

### Pitfall 6: Views Cannot Be COUNT(*)'d Efficiently
**What goes wrong:** `SELECT COUNT(*) FROM lake.some_view` executes the full view query, which for large filtered views can be slow.
**Why it happens:** DuckLake views are defined SQL, not materialised.
**How to avoid:** Accept this cost -- views are filtered subsets and should be fast enough. For the EPC WECA views, the filter reduces 19M to ~hundreds of thousands.
**Warning signs:** Slow catalogue generation for view row counts.

## Code Examples

### Spatial Metadata for Catalogue (Bounding Box, Geometry Type)
```sql
-- Get spatial metadata for a DuckLake spatial table
INSTALL spatial; LOAD spatial;

SELECT
  ST_GeometryType(shape) AS geometry_type,
  COUNT(*) AS geom_count,
  ST_XMin(ST_Extent(shape)) AS bbox_xmin,
  ST_YMin(ST_Extent(shape)) AS bbox_ymin,
  ST_XMax(ST_Extent(shape)) AS bbox_xmax,
  ST_YMax(ST_Extent(shape)) AS bbox_ymax
FROM lake.bdline_ua_lep_tbl
GROUP BY ST_GeometryType(shape);
```
**Confidence:** HIGH -- `ST_Extent` and `ST_GeometryType` are standard DuckDB spatial functions.

### Example Value Sampling (Efficient)
```sql
-- Sample up to 3 distinct non-null values per column, capped scan
SELECT DISTINCT col_name
FROM (SELECT col_name FROM lake.table_name WHERE col_name IS NOT NULL LIMIT 1000)
LIMIT 3;
```
**Confidence:** HIGH -- standard DuckDB subquery pattern.

### Catalogue View SQL (datasets_catalogue)
```sql
-- Datasets catalogue: one row per table/view in DuckLake
CREATE OR REPLACE TABLE lake.datasets_catalogue AS
WITH base_tables AS (
  SELECT
    table_name AS name,
    comment AS description,
    'table' AS type
  FROM duckdb_tables()
  WHERE database_name = 'lake'
    AND table_name NOT IN ('datasets_catalogue', 'columns_catalogue')
),
base_views AS (
  SELECT
    view_name AS name,
    comment AS description,
    'view' AS type
  FROM duckdb_views()
  WHERE database_name = 'lake'
)
SELECT * FROM base_tables
UNION ALL
SELECT * FROM base_views
ORDER BY type, name;
```
**Confidence:** MEDIUM -- `duckdb_views()` comment field needs verification; may be NULL for all views.

### Row Count via DuckDB CLI
```r
# Get row count for a DuckLake table/view
count_sql <- sprintf("SELECT COUNT(*) AS n FROM lake.%s;", tbl_name)
# Execute via CLI, parse output
```
**Confidence:** HIGH -- same pattern used in validate_ducklake.R

### Console Summary Table (R)
```r
# Print summary using cat + sprintf (no external dependency needed)
cat(sprintf("%-35s %10s %8s %6s\n", "Table", "Rows", "Secs", "Status"))
cat(paste(rep("-", 65), collapse = ""), "\n")
for (i in seq_len(nrow(summary_df))) {
  cat(sprintf("%-35s %10s %8.1f %6s\n",
    summary_df$table[i],
    format(summary_df$rows[i], big.mark = ","),
    summary_df$seconds[i],
    summary_df$status[i]))
}
```
**Confidence:** HIGH -- same formatting pattern used in export_spatial_pins.R summary.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Separate scripts per operation | Single refresh.R entry point | Phase 5 (new) | Data owner runs one command |
| No catalogue | DuckLake views + pinned parquet | Phase 5 (new) | Analysts discover datasets without asking |
| Manual re-run of multiple scripts | Automated re-export of all tables | Phase 5 (new) | Refresh is repeatable and validated |

**Deprecated/outdated:**
- `create_ducklake.sql` / `create_ducklake.R`: Still valid for initial setup but not called during refresh
- `export_pins.R` / `export_spatial_pins.R`: Logic incorporated into refresh.R; originals remain as reference

## Open Questions

1. **View comments in DuckLake**
   - What we know: `duckdb_views()` has a `comment` column but we have not applied COMMENT ON VIEW for any view.
   - What's unclear: Whether the catalogue should manufacture descriptions for views (e.g. "WECA-filtered subset of {source_table}").
   - Recommendation: Generate view descriptions programmatically from view name patterns. LOW risk.

2. **Last updated date source**
   - What we know: DuckLake `ducklake_snapshot` has `snapshot_timestamp`. Current refresh timestamp is also available.
   - What's unclear: Whether to use the DuckLake snapshot timestamp or the R `Sys.time()` at refresh.
   - Recommendation: Use the R script's start timestamp (`Sys.time()`) as `last_updated` for all tables in a refresh run. Simpler and more reliable than querying per-table snapshot times.

3. **Catalogue tables as DuckLake tables vs views**
   - What we know: User wants catalogue "views" but also wants them pinned to S3.
   - What's unclear: DuckLake views cannot be exported as pins directly; they need materialisation.
   - Recommendation: Create as DuckLake tables (`CREATE OR REPLACE TABLE`) so they can be queried via SQL and also exported as pins. The user said "DuckLake views plus exported as pinned parquet" -- materialised tables satisfy both needs.

4. **Bounding box for spatial catalogue entries**
   - What we know: `ST_Extent()` returns aggregate bounding box. CRS is not embedded in DuckDB GeoParquet.
   - What's unclear: Format for bounding box in catalogue (4 separate columns vs WKT vs JSON).
   - Recommendation: Four separate numeric columns (`bbox_xmin`, `bbox_ymin`, `bbox_xmax`, `bbox_ymax`) plus a `crs` text column. Most queryable format.

## Sources

### Primary (HIGH confidence)
- [/websites/ducklake_select_stable](https://ducklake.select/docs/stable/) - DuckLake specification: snapshots, metadata tables, time travel, retention, maintenance
- [/rstudio/pins-r](https://pins.rstudio.com/) - pins R package: pin_write, pin_upload, board_s3, versioning, metadata
- Existing codebase scripts: `export_pins.R`, `export_spatial_pins.R`, `create_ducklake.R`, `create_ducklake.sql`, `recreate_spatial_ducklake.sql`, `validate_ducklake.R`

### Secondary (MEDIUM confidence)
- [DuckLake Tables Specification](https://ducklake.select/docs/stable/specification/tables/overview) - ducklake_table, ducklake_column, ducklake_snapshot internal table schemas
- [DuckLake Maintenance Docs](https://ducklake.select/docs/stable/duckdb/maintenance/recommended_maintenance) - Snapshot expiration and file cleanup behaviour

### Tertiary (LOW confidence)
- `duckdb_views()` comment field availability -- needs runtime verification

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All libraries already in use; no new dependencies needed
- Architecture: HIGH - Consolidation of existing working patterns; no new technical ground
- Pitfalls: HIGH - All pitfalls already encountered and solved in Phases 2-4
- Catalogue SQL: MEDIUM - DuckLake metadata queries verified via Context7 but view comments untested

**Research date:** 2026-02-24
**Valid until:** 2026-03-24 (stable domain; DuckLake 0.3 spec unlikely to change before 1.0)
