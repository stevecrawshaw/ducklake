# apply_comments.R
# Extracts table and column comments from the source DuckDB database and
# applies them to the DuckLake catalogue. Also creates views.
#
# The R duckdb package (v1.4.4) works for reading from the source database,
# but the DuckLake catalogue requires the ducklake extension which is only
# available via DuckDB CLI.
#
# Usage: Rscript scripts/apply_comments.R
#   (run from project root directory)

library(duckdb)
library(DBI)

# --- Configuration ---
SOURCE_DB <- "data/mca_env_base.duckdb"
DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH <- "s3://stevecrawshaw-bucket/ducklake/data/"
VIEWS_SQL_FILE <- "scripts/create_views.sql"

cat("=== DuckLake Comments and Views ===\n")
cat(sprintf("Source DB:      %s\n", SOURCE_DB))
cat(sprintf("Catalogue file: %s\n", DUCKLAKE_FILE))
cat(sprintf("Data path:      %s\n\n", DATA_PATH))

# --- Step 1: Extract comments from source using R duckdb package ---
cat("--- Extracting comments from source database ---\n")

src_con <- dbConnect(duckdb(), dbdir = SOURCE_DB, read_only = TRUE)

# Table comments
table_comments <- dbGetQuery(src_con, "
  SELECT table_name, comment
  FROM duckdb_tables()
  WHERE schema_name = 'main' AND NOT internal AND comment IS NOT NULL
  ORDER BY table_name
")
cat(sprintf("Found %d table comments\n", nrow(table_comments)))

# Column comments -- only for base tables (not views) since DuckLake only has tables
# Filter by joining with duckdb_tables() to exclude view columns
column_comments <- dbGetQuery(src_con, "
  SELECT c.table_name, c.column_name, c.comment
  FROM duckdb_columns() c
  INNER JOIN duckdb_tables() t
    ON c.table_name = t.table_name AND c.schema_name = t.schema_name
  WHERE c.schema_name = 'main'
    AND c.comment IS NOT NULL AND c.comment <> ''
    AND NOT t.internal
  ORDER BY c.table_name, c.column_name
")
cat(sprintf("Found %d column comments (tables only, views excluded)\n\n",
            nrow(column_comments)))

dbDisconnect(src_con, shutdown = TRUE)

# --- Step 2: Generate COMMENT ON SQL statements ---
cat("--- Generating COMMENT ON SQL ---\n")

# Helper to escape single quotes in SQL strings
escape_sql <- function(s) {
  gsub("'", "''", s, fixed = TRUE)
}

# Table comment statements
table_stmts <- vapply(seq_len(nrow(table_comments)), function(i) {
  sprintf(
    "COMMENT ON TABLE lake.%s IS '%s'",
    table_comments$table_name[i],
    escape_sql(table_comments$comment[i])
  )
}, character(1))

# Column comment statements
column_stmts <- vapply(seq_len(nrow(column_comments)), function(i) {
  sprintf(
    "COMMENT ON COLUMN lake.%s.%s IS '%s'",
    column_comments$table_name[i],
    column_comments$column_name[i],
    escape_sql(column_comments$comment[i])
  )
}, character(1))

cat(sprintf("Generated %d table COMMENT ON statements\n", length(table_stmts)))
cat(sprintf("Generated %d column COMMENT ON statements\n\n", length(column_stmts)))

# --- Step 3: Build combined SQL for DuckDB CLI ---
# Preamble: install extensions, create secret, attach catalogue
preamble <- c(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s');",
    DUCKLAKE_FILE, DATA_PATH
  )
)

# Combine all statements
all_stmts <- c(
  preamble,
  "",
  "-- Table comments",
  paste0(table_stmts, ";"),
  "",
  "-- Column comments",
  paste0(column_stmts, ";"),
  "",
  "-- Verification",
  "SELECT table_name, comment FROM duckdb_tables() WHERE database_name = 'lake' AND comment IS NOT NULL ORDER BY table_name;",
  "SELECT COUNT(*) AS column_comments_applied FROM duckdb_columns() WHERE database_name = 'lake' AND comment IS NOT NULL;"
)

# Write to temp file
tmp_sql <- "scripts/.tmp_apply_comments.sql"
writeLines(all_stmts, tmp_sql, useBytes = TRUE)

cat("--- Executing COMMENT ON statements via DuckDB CLI ---\n")
cat(sprintf("SQL file: %s (%d lines)\n\n", tmp_sql, length(all_stmts)))

# Execute via DuckDB CLI
cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql)
result <- system(cmd, intern = TRUE, timeout = 300)

# Print output
if (length(result) > 0) {
  cat("DuckDB CLI output:\n")
  for (line in result) {
    cat(sprintf("  %s\n", line))
  }
  cat("\n")
}

exit_code <- attr(result, "status")
if (!is.null(exit_code) && exit_code != 0) {
  cat(sprintf("WARNING: DuckDB CLI exited with code %d\n", exit_code))
  cat("Some statements may have failed. Check output above.\n\n")
}

# Clean up temp file
file.remove(tmp_sql)

cat("=== Comments application complete ===\n\n")

# ============================================================
# Step 4: Create views from scripts/create_views.sql
# ============================================================
cat("=== Creating Views ===\n\n")

if (!file.exists(VIEWS_SQL_FILE)) {
  cat(sprintf("ERROR: Views SQL file not found: %s\n", VIEWS_SQL_FILE))
  quit(status = 1)
}

# Read the views SQL file
views_sql <- readLines(VIEWS_SQL_FILE, warn = FALSE) |> paste(collapse = "\n")

# Build the full SQL: preamble + drop existing views (idempotent) + create views + verify
# First, extract view names from the SQL to generate DROP IF EXISTS statements
view_names <- regmatches(
  views_sql,
  gregexpr("CREATE VIEW lake\\.(\\w+)", views_sql)
)[[1]]
view_names <- sub("CREATE VIEW lake\\.", "", view_names)

cat(sprintf("Found %d view definitions in %s\n", length(view_names), VIEWS_SQL_FILE))
cat("Views:", paste(view_names, collapse = ", "), "\n\n")

# Build combined SQL with preamble, drops, creates, and verification
drop_stmts <- paste0("DROP VIEW IF EXISTS lake.", view_names, ";")

views_full_sql <- paste(
  c(
    preamble,
    "",
    "-- Drop existing views (idempotent re-run)",
    drop_stmts,
    "",
    "-- Create views from create_views.sql",
    views_sql,
    "",
    "-- Verification",
    "SELECT view_name FROM duckdb_views() WHERE database_name = 'lake' ORDER BY view_name;",
    "SELECT COUNT(*) AS weca_lep_la_rows FROM lake.weca_lep_la_vw;",
    "SELECT COUNT(*) AS ghg_weca_rows FROM lake.la_ghg_emissions_weca_vw;"
  ),
  collapse = "\n"
)

tmp_views_sql <- "scripts/.tmp_create_views.sql"
writeLines(views_full_sql, tmp_views_sql, useBytes = TRUE)

cat("--- Executing CREATE VIEW statements via DuckDB CLI ---\n\n")

views_cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_views_sql)
views_result <- system(views_cmd, intern = TRUE, timeout = 120)

if (length(views_result) > 0) {
  cat("DuckDB CLI output:\n")
  for (line in views_result) {
    cat(sprintf("  %s\n", line))
  }
  cat("\n")
}

views_exit <- attr(views_result, "status")
if (!is.null(views_exit) && views_exit != 0) {
  cat(sprintf("WARNING: Views creation exited with code %d\n", views_exit))
  cat("Some views may have failed. Check output above.\n\n")
}

file.remove(tmp_views_sql)

cat("=== Views creation complete ===\n")
cat("=== Done ===\n")
