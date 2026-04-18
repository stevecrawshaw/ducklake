# DuckLake 1.0 Upgrade Plan

**Status:** Pending implementation  
**Requires:** DuckDB CLI v1.5.2+ installed manually before running Phase 2

## Breaking change

`AUTOMATIC_MIGRATION` is now **off by default** in DuckLake 1.0. Attaching the existing `data/mca_env.ducklake` (0.x schema) with the new extension without this flag raises:

```
DuckLake catalog version mismatch: catalog version is 0.3, but the extension requires version 1.0.
```

All other syntax (ATTACH, secrets, COMMENT ON, duckdb_views(), spatial columns) is unchanged.

## Run order

```
1. Upgrade DuckDB CLI to v1.5.2+         ← manual (download from github.com/duckdb/duckdb/releases)
2. Update pyproject.toml + uv sync       ← Phase 1 (code change)
3. Rscript scripts/migrate_ducklake.R    ← Phase 2 (one-time, run once)
4. Verify catalogue attaches cleanly     ← Phase 2 verification
5. Rscript scripts/refresh.R             ← confirm normal pipeline still works
```

## Phase 1 — Python package bump

**File:** `pyproject.toml`  
Change `"duckdb>=1.4.4"` → `"duckdb>=1.5.2"`, then `uv sync`.

## Phase 2 — One-time catalogue migration script

**Create:** `scripts/migrate_ducklake.R`

A standalone script that attaches `data/mca_env.ducklake` with `AUTOMATIC_MIGRATION` to upgrade the internal schema from 0.x to 1.0 in place. Backs up the `.ducklake` file first, restores on failure. After this runs successfully, all existing ATTACH statements in all other scripts work without modification.

```r
# scripts/migrate_ducklake.R
# One-time migration of data/mca_env.ducklake from DuckLake 0.x schema to 1.0.
# Requires DuckDB CLI >= 1.5.2 and write access to data/mca_env.ducklake.
# Run once after upgrading DuckDB CLI; never needed again.
#
# Usage: Rscript scripts/migrate_ducklake.R  (from project root)

DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH     <- "s3://stevecrawshaw-bucket/ducklake/data/"

cat("=== DuckLake 0.x -> 1.0 Schema Migration ===\n")
cat(sprintf("Catalogue: %s\n\n", DUCKLAKE_FILE))

if (!file.exists(DUCKLAKE_FILE)) stop("Catalogue file not found: ", DUCKLAKE_FILE)

backup_file <- paste0(DUCKLAKE_FILE, ".premigration.bak")
file.copy(DUCKLAKE_FILE, backup_file, overwrite = FALSE)
cat(sprintf("Backup written to: %s\n\n", backup_file))

sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs;   LOAD httpfs;",
  "INSTALL aws;      LOAD aws;",
  "INSTALL spatial;  LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', AUTOMATIC_MIGRATION);",
    gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH
  ),
  "SELECT 'Migration complete' AS status;",
  sep = "\n"
)

tmp_sql <- "scripts/.tmp_migrate.sql"
writeLines(sql, tmp_sql, useBytes = TRUE)
cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql)
cat("Running migration...\n")
result <- system(cmd, intern = TRUE, timeout = 120)
file.remove(tmp_sql)

exit_code <- attr(result, "status")
if (!is.null(exit_code) && exit_code != 0) {
  cat("Migration FAILED. Restoring from backup...\n")
  file.copy(backup_file, DUCKLAKE_FILE, overwrite = TRUE)
  stop("Migration failed. Catalogue restored. Check DuckDB CLI version (need >= 1.5.2).")
}

for (line in result) cat(sprintf("  %s\n", line))
cat(sprintf("\nDone. Backup retained at: %s\n", backup_file))
cat("Delete the backup once you have verified the catalogue works.\n")
```

## Phase 3 — Fix `create_ducklake.sql` spatial tables

**File:** `scripts/create_ducklake.sql`, Step 7  
Remove the BLOB workaround (written before DuckLake supported geometry). Replace with `ST_GeomFromWKB` / `ST_Multi` to match what `recreate_spatial_ducklake.sql` and `refresh.R` already do.

Replace the 8 BLOB-cast CREATE TABLE statements with:

```sql
-- Step 7: Register spatial tables (8 tables)
-- DuckLake 1.0 supports GEOMETRY natively (requires spatial extension loaded above).
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.bdline_ua_lep_diss_tbl;
CREATE TABLE lake.bdline_ua_lep_tbl      AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.bdline_ua_lep_tbl;
CREATE TABLE lake.bdline_ua_weca_diss_tbl AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.bdline_ua_weca_diss_tbl;
CREATE TABLE lake.bdline_ward_lep_tbl    AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.bdline_ward_lep_tbl;
CREATE TABLE lake.ca_boundaries_bgc_tbl  AS SELECT * EXCLUDE(geom),  ST_Multi(geom) AS geom        FROM source.ca_boundaries_bgc_tbl;
CREATE TABLE lake.codepoint_open_lep_tbl AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.codepoint_open_lep_tbl;
CREATE TABLE lake.lsoa_2021_lep_tbl      AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape, ST_IsValid(ST_GeomFromWKB(shape)) AS geom_valid FROM source.lsoa_2021_lep_tbl;
CREATE TABLE lake.open_uprn_lep_tbl      AS SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape FROM source.open_uprn_lep_tbl;
```

## Phase 4 — Update CLAUDE.md

- Bump minimum DuckDB version to 1.5.2
- Note `AUTOMATIC_MIGRATION` is off by default (one-time migration script handles this)
- Note `GEOMETRY` is now a DuckDB core built-in type (spatial extension still needed for ST_* functions)
- Remove stale "DuckLake does not support GEOMETRY" note from `create_ducklake.sql` comment

## What does NOT change

| Component | Status |
|---|---|
| `refresh.R` ATTACH syntax | Unchanged — works once migrated |
| `apply_comments.R` | Unchanged |
| `validate_ducklake.R` | Unchanged |
| `recreate_spatial_ducklake.sql` | Unchanged — already correct |
| `INSTALL/LOAD` lines in all scripts | Unchanged |
| S3 `CREATE SECRET` | Unchanged |
| `duckdb_views()`, `duckdb_columns()` queries | Unchanged |
| `COMMENT ON TABLE/COLUMN` syntax | Unchanged |
| Python `main.py`, `validate_pins.py` | Unchanged |
