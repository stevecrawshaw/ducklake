# test_interop.R
# Cross-language interop test: write a single pin from R to S3.
# The corresponding Python script (test_interop.py) reads it back.
#
# Usage: Rscript scripts/test_interop.R

library(duckdb)
library(DBI)
library(pins)
library(arrow)

# --- Configuration ---
SOURCE_DB <- "data/mca_env_base.duckdb"
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
AWS_REGION <- "eu-west-2"

# --- Connect to source DB (read-only) ---
con <- dbConnect(duckdb(), dbdir = SOURCE_DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# --- Find smallest non-spatial table ---
tables_df <- dbGetQuery(con, "
  SELECT table_name, comment, estimated_size, column_count
  FROM duckdb_tables()
  WHERE schema_name = 'main'
    AND internal = false
  ORDER BY table_name
")

columns_df <- dbGetQuery(con, "
  SELECT table_name, column_name, data_type, comment
  FROM duckdb_columns()
  WHERE schema_name = 'main'
  ORDER BY table_name, column_index
")

# Identify spatial tables
spatial_tables <- unique(
  columns_df$table_name[grepl("BLOB|GEOMETRY|WKB", columns_df$data_type, ignore.case = TRUE)]
)

nonspatial <- tables_df[!tables_df$table_name %in% spatial_tables, ]

# Get actual row counts
nonspatial$row_count <- vapply(nonspatial$table_name, function(tbl) {
  dbGetQuery(con, sprintf('SELECT COUNT(*) AS n FROM "%s"', tbl))$n
}, numeric(1))

# Pick smallest
smallest_idx <- which.min(nonspatial$row_count)
test_table <- nonspatial$table_name[smallest_idx]
test_comment <- nonspatial$comment[smallest_idx]

cat(sprintf("Test table: %s (%d rows)\n", test_table, nonspatial$row_count[smallest_idx]))
cat(sprintf("Table comment: %s\n", test_comment))

# --- Read table data ---
df <- dbReadTable(con, test_table)
cat(sprintf("Data frame: %d rows x %d cols\n", nrow(df), ncol(df)))

# --- Get column metadata ---
table_cols <- columns_df[columns_df$table_name == test_table, ]
col_comments <- setNames(
  ifelse(is.na(table_cols$comment), "", table_cols$comment),
  table_cols$column_name
)
col_types <- setNames(table_cols$data_type, table_cols$column_name)

# --- Create S3 board ---
board <- board_s3(
  bucket = S3_BUCKET,
  prefix = S3_PREFIX,
  region = AWS_REGION,
  versioned = TRUE
)

# --- Write pin ---
pin_name <- test_table
cat(sprintf("Writing pin: %s\n", pin_name))

pin_write(
  board,
  x = df,
  name = pin_name,
  type = "parquet",
  title = if (is.na(test_comment) || test_comment == "") test_table else test_comment,
  description = if (is.na(test_comment) || test_comment == "") test_table else test_comment,
  metadata = list(
    source_db = "ducklake",
    columns = as.list(col_comments),
    column_types = as.list(col_types)
  )
)

cat("Pin written successfully.\n")

# --- Verify: read pin back ---
df_back <- pin_read(board, pin_name)
stopifnot(nrow(df_back) == nrow(df))
stopifnot(ncol(df_back) == ncol(df))
cat(sprintf("Read back: %d rows x %d cols (matches)\n", nrow(df_back), ncol(df_back)))

# --- Verify: check metadata ---
meta <- pin_meta(board, pin_name)
cat(sprintf("Pin title: %s\n", meta$title))
cat(sprintf("Pin description: %s\n", meta$description))
cat("Custom metadata (user):\n")
str(meta$user)

cat("\nR INTEROP TEST PASSED\n")
