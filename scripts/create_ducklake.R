# create_ducklake.R
# Creates a DuckLake catalogue and registers all 18 tables from the source
# DuckDB database. Uses the DuckDB CLI because the R DuckDB package (v1.4.4)
# has extension compatibility issues with ducklake.
#
# The catalogue file is local (data/mca_env.ducklake) with data on S3.
# Tables are copied individually (COPY FROM DATABASE fails on spatial types).
#
# Usage: Rscript scripts/create_ducklake.R
#   (run from project root directory)

# --- Configuration ---
SQL_FILE <- "scripts/create_ducklake.sql"
SOURCE_DB <- "data/mca_env_base.duckdb"
DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH <- "s3://stevecrawshaw-bucket/ducklake/data/"

cat("=== DuckLake Catalogue Creation ===\n")
cat(sprintf("SQL file:       %s\n", SQL_FILE))
cat(sprintf("Source DB:      %s\n", SOURCE_DB))
cat(sprintf("Catalogue file: %s\n", DUCKLAKE_FILE))
cat(sprintf("Data path:      %s\n\n", DATA_PATH))

# --- Clean up any previous catalogue file ---
if (file.exists(DUCKLAKE_FILE)) {
  cat("Removing existing catalogue file...\n")
  file.remove(DUCKLAKE_FILE)
  # Also remove WAL file if present
  wal_file <- paste0(DUCKLAKE_FILE, ".wal")
  if (file.exists(wal_file)) file.remove(wal_file)
}

# --- Read and parse SQL file ---
sql_text <- readLines(SQL_FILE, warn = FALSE) |> paste(collapse = "\n")

# Split on semicolons, clean up
statements <- strsplit(sql_text, ";")[[1]]
statements <- trimws(statements)
# Remove empty and comment-only entries
statements <- statements[nchar(statements) > 0]
# Remove pure comment lines from each statement
statements <- vapply(statements, function(s) {
  lines <- strsplit(s, "\n")[[1]]
  lines <- lines[!grepl("^\\s*--", lines)]
  paste(lines, collapse = "\n")
}, character(1), USE.NAMES = FALSE)
statements <- statements[nchar(trimws(statements)) > 0]

cat(sprintf("Parsed %d SQL statements from %s\n\n", length(statements), SQL_FILE))

# --- Execute each statement via DuckDB CLI ---
# We run all statements in a single DuckDB session by writing a combined
# SQL file and using duckdb -c with the .read command.
# To avoid Windows path issues, write to a project-local temp file.
cat("Executing via DuckDB CLI...\n\n")

# Build combined SQL
full_sql <- paste(paste0(statements, ";"), collapse = "\n")

# Write to a project-local temp file (avoids Windows path issues)
tmp_sql_local <- "scripts/.tmp_create_ducklake.sql"
writeLines(full_sql, tmp_sql_local, useBytes = TRUE)

# Execute using duckdb -init which reads and executes the file
# Use -no-stdin to prevent interactive mode
cmd <- sprintf(
  'duckdb -init "%s" -c "SELECT 1;" -no-stdin',
  tmp_sql_local
)
cat(sprintf("Running: %s\n\n", cmd))

result <- system(cmd, intern = TRUE, timeout = 600)

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
  cat("Some statements may have failed. Checking results...\n\n")
}

# Clean up temp file
file.remove(tmp_sql_local)

# --- Verification ---
cat("=== Verification ===\n\n")

# Check catalogue file exists
if (file.exists(DUCKLAKE_FILE)) {
  fsize <- file.info(DUCKLAKE_FILE)$size
  cat(sprintf("Catalogue file: %s (%.1f KB)\n", DUCKLAKE_FILE, fsize / 1024))
} else {
  cat("ERROR: Catalogue file not created!\n")
  quit(status = 1)
}

# Verify tables via DuckDB CLI
verify_sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
    DUCKLAKE_FILE, DATA_PATH
  ),
  "SELECT table_name FROM information_schema.tables WHERE table_catalog = 'lake' AND table_schema = 'main' AND table_type = 'BASE TABLE' ORDER BY table_name;",
  "SELECT COUNT(*) AS ca_la_lookup_rows FROM lake.ca_la_lookup_tbl;",
  "SELECT COUNT(*) AS boundary_lookup_rows FROM lake.boundary_lookup_tbl;",
  "SELECT COUNT(*) AS la_ghg_rows FROM lake.la_ghg_emissions_tbl;",
  sep = "\n"
)

tmp_verify_local <- "scripts/.tmp_verify_ducklake.sql"
writeLines(verify_sql, tmp_verify_local, useBytes = TRUE)

cat("\n--- Tables in DuckLake catalogue ---\n")
verify_cmd <- sprintf(
  'duckdb -init "%s" -c "SELECT 1;" -no-stdin',
  tmp_verify_local
)
verify_result <- system(verify_cmd, intern = TRUE, timeout = 120)

if (length(verify_result) > 0) {
  for (line in verify_result) {
    cat(sprintf("  %s\n", line))
  }
  cat("\n")
}

verify_exit <- attr(verify_result, "status")
if (!is.null(verify_exit) && verify_exit != 0) {
  cat(sprintf("\nWARNING: Verification exited with code %d\n", verify_exit))
}

file.remove(tmp_verify_local)

cat("\n=== Done ===\n")
