# extract_metadata.R
# Connects to source DuckDB and extracts table/column metadata.
# Identifies spatial tables (excluded from export) vs non-spatial tables.
# Saves metadata to data/table_metadata.rds
#
# Usage: Rscript scripts/extract_metadata.R

library(duckdb)
library(DBI)

# --- Configuration ---
SOURCE_DB <- "data/mca_env_base.duckdb"

# --- Connect (read-only) ---
con <- dbConnect(duckdb(), dbdir = SOURCE_DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# --- Get all tables in main schema ---
tables_df <- dbGetQuery(con, "
  SELECT
    table_name,
    comment,
    estimated_size,
    column_count
  FROM duckdb_tables()
  WHERE schema_name = 'main'
    AND internal = false
  ORDER BY table_name
")

cat("=== DuckDB Metadata Extraction ===\n")
cat(sprintf("Source: %s\n", SOURCE_DB))
cat(sprintf("Total tables found: %d\n\n", nrow(tables_df)))

# --- Get all column metadata ---
columns_df <- dbGetQuery(con, "
  SELECT
    table_name,
    column_name,
    data_type,
    comment
  FROM duckdb_columns()
  WHERE schema_name = 'main'
  ORDER BY table_name, column_index
")

# --- Identify spatial tables ---
spatial_columns <- columns_df[
  grepl("BLOB|GEOMETRY|WKB", columns_df$data_type, ignore.case = TRUE),
]
spatial_tables <- unique(spatial_columns$table_name)

tables_df$is_spatial <- tables_df$table_name %in% spatial_tables

# --- Get actual row counts for non-spatial tables ---
tables_df$row_count <- NA_integer_
for (i in seq_len(nrow(tables_df))) {
  tbl <- tables_df$table_name[i]
  count <- dbGetQuery(con, sprintf('SELECT COUNT(*) AS n FROM "%s"', tbl))$n

  tables_df$row_count[i] <- count
}

# --- Split into spatial and non-spatial ---
spatial_df <- tables_df[tables_df$is_spatial, ]
nonspatial_df <- tables_df[!tables_df$is_spatial, ]

# --- Print spatial tables (excluded) ---
cat(sprintf("--- Spatial tables (EXCLUDED from export): %d ---\n", nrow(spatial_df)))
if (nrow(spatial_df) > 0) {
  for (i in seq_len(nrow(spatial_df))) {
    cat(sprintf("  [SPATIAL] %s  (%d rows, %d cols)\n",
                spatial_df$table_name[i],
                spatial_df$row_count[i],
                spatial_df$column_count[i]))
    # Show which columns are spatial
    sp_cols <- spatial_columns[spatial_columns$table_name == spatial_df$table_name[i], ]
    for (j in seq_len(nrow(sp_cols))) {
      cat(sprintf("           -> %s (%s)\n", sp_cols$column_name[j], sp_cols$data_type[j]))
    }
  }
}
cat("\n")

# --- Print non-spatial tables (to export) ---
cat(sprintf("--- Non-spatial tables (TO EXPORT): %d ---\n", nrow(nonspatial_df)))
if (nrow(nonspatial_df) > 0) {
  for (i in seq_len(nrow(nonspatial_df))) {
    comment_str <- if (is.na(nonspatial_df$comment[i]) || nonspatial_df$comment[i] == "") {
      "(no comment)"
    } else {
      nonspatial_df$comment[i]
    }
    cat(sprintf("  %s\n    Comment: %s\n    Rows: %d | Cols: %d\n",
                nonspatial_df$table_name[i],
                comment_str,
                nonspatial_df$row_count[i],
                nonspatial_df$column_count[i]))
  }
}
cat("\n")

# --- Save metadata ---
# Filter columns to non-spatial tables only for the export list
nonspatial_columns <- columns_df[columns_df$table_name %in% nonspatial_df$table_name, ]

metadata <- list(
  tables = nonspatial_df,
  columns = nonspatial_columns,
  spatial_tables = spatial_df,
  spatial_columns = spatial_columns
)

output_path <- "data/table_metadata.rds"
saveRDS(metadata, output_path)
cat(sprintf("Metadata saved to: %s\n", output_path))
cat("Done.\n")
