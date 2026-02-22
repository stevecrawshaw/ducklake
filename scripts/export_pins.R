# export_pins.R
# Exports all non-spatial tables from source DuckDB as pins to S3 with metadata.
# Large tables (>5M rows) use pin_upload with DuckDB COPY TO to avoid OOM.
#
# Usage: Rscript scripts/export_pins.R

library(pins)
library(duckdb)
library(DBI)
library(arrow)

# --- Configuration ---
SOURCE_DB <- "data/mca_env_base.duckdb"
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
S3_REGION <- "eu-west-2"
LARGE_TABLE_THRESHOLD <- 5000000 # rows; tables above this use pin_upload
CHUNK_SIZE <- 3000000 # rows per parquet chunk for large tables (keeps files under ~500MB)

# --- Connect to source DuckDB (read-only) ---
cat("=== DuckLake Pin Export ===\n")
cat(sprintf("Source: %s\n", SOURCE_DB))
cat(sprintf("Target: s3://%s/%s\n", S3_BUCKET, S3_PREFIX))
cat(sprintf("Large table threshold: %s rows\n\n", format(LARGE_TABLE_THRESHOLD, big.mark = ",")))

con <- dbConnect(duckdb(), dbdir = SOURCE_DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# --- Create S3 board ---
board <- board_s3(
  bucket = S3_BUCKET,
  prefix = S3_PREFIX,
  region = S3_REGION,
  versioned = TRUE
)

# --- Get all non-internal main-schema tables with comments and estimated_size ---
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

# --- Identify and exclude spatial tables ---
spatial_columns <- columns_df[
  grepl("BLOB|GEOMETRY|WKB", columns_df$data_type, ignore.case = TRUE),
]
spatial_tables <- unique(spatial_columns$table_name)

nonspatial_tables <- tables_df[!tables_df$table_name %in% spatial_tables, ]

cat(sprintf("Tables found: %d total, %d spatial (excluded), %d to export\n\n",
            nrow(tables_df), length(spatial_tables), nrow(nonspatial_tables)))

# --- Get actual row counts ---
nonspatial_tables$row_count <- vapply(
  nonspatial_tables$table_name,
  function(tbl) {
    dbGetQuery(con, sprintf('SELECT COUNT(*) AS n FROM "%s"', tbl))$n
  },
  numeric(1)
)

# --- Export each non-spatial table ---
results <- list()
total_rows <- 0

for (i in seq_len(nrow(nonspatial_tables))) {
  tbl_name <- nonspatial_tables$table_name[i]
  tbl_comment <- nonspatial_tables$comment[i]
  row_count <- nonspatial_tables$row_count[i]
  is_large <- row_count > LARGE_TABLE_THRESHOLD

  # Get column metadata for this table
  col_meta <- columns_df[columns_df$table_name == tbl_name, ]

  # Build title from comment or table name

  title <- if (is.na(tbl_comment) || tbl_comment == "") {
    tbl_name
  } else {
    tbl_comment
  }

  # Build custom metadata
  meta <- list(
    source_db = "ducklake",
    columns = setNames(
      as.list(ifelse(is.na(col_meta$comment), "", col_meta$comment)),
      col_meta$column_name
    ),
    column_types = setNames(
      as.list(col_meta$data_type),
      col_meta$column_name
    )
  )

  method <- if (is_large) "pin_upload" else "pin_write"
  cat(sprintf("[%d/%d] %s (%s rows) [%s]... ",
              i, nrow(nonspatial_tables), tbl_name,
              format(row_count, big.mark = ","), method))

  result <- tryCatch({
    if (is_large) {
      # --- Large table: DuckDB COPY TO chunked parquet files, then pin_upload ---
      # Split into chunks to avoid curl 2GB upload limit (postfieldsize overflow)
      n_chunks <- ceiling(row_count / CHUNK_SIZE)
      temp_paths <- character(n_chunks)

      cat(sprintf("(%d chunks)... ", n_chunks))

      for (chunk_i in seq_len(n_chunks)) {
        offset <- (chunk_i - 1) * CHUNK_SIZE
        chunk_file <- file.path(
          tempdir(),
          sprintf("%s_part%03d.parquet", tbl_name, chunk_i)
        )
        temp_paths[chunk_i] <- chunk_file

        dbExecute(con, sprintf(
          "COPY (SELECT * FROM \"%s\" LIMIT %d OFFSET %d) TO '%s' (FORMAT PARQUET, ROW_GROUP_SIZE 100000)",
          tbl_name, CHUNK_SIZE, offset,
          gsub("\\\\", "/", chunk_file)
        ))
      }

      on.exit(unlink(temp_paths), add = TRUE)

      pin_upload(
        board,
        paths = temp_paths,
        name = tbl_name,
        title = title,
        description = sprintf("%s (%s rows, %d columns, %d parquet files)",
                              title, format(row_count, big.mark = ","),
                              nrow(col_meta), n_chunks),
        metadata = meta
      )
    } else {
      # --- Standard table: dbReadTable then pin_write ---
      df <- dbReadTable(con, tbl_name)

      pin_write(
        board,
        x = df,
        name = tbl_name,
        type = "parquet",
        title = title,
        description = sprintf("%s (%s rows, %d columns)",
                              title, format(row_count, big.mark = ","),
                              nrow(col_meta)),
        metadata = meta
      )

      # Free memory
      rm(df)
    }

    list(success = TRUE, error = NULL)
  }, error = function(e) {
    list(success = FALSE, error = conditionMessage(e))
  })

  results[[tbl_name]] <- list(
    rows = row_count,
    method = method,
    success = result$success,
    error = result$error
  )

  if (result$success) {
    cat("OK\n")
    total_rows <- total_rows + row_count
  } else {
    cat(sprintf("FAILED: %s\n", result$error))
  }
}

# --- Summary ---
successes <- sum(vapply(results, function(r) r$success, logical(1)))
failures <- sum(vapply(results, function(r) !r$success, logical(1)))

cat("\n=== Export Summary ===\n")
cat(sprintf("Tables exported: %d/%d\n", successes, length(results)))
cat(sprintf("Total rows: %s\n", format(total_rows, big.mark = ",")))
cat(sprintf("Failures: %d\n", failures))

if (failures > 0) {
  cat("\n--- Failed Tables ---\n")
  for (name in names(results)) {
    r <- results[[name]]
    if (!r$success) {
      cat(sprintf("  %s: %s\n", name, r$error))
    }
  }
}

# --- Verify: pin_list ---
cat("\n=== Pin List (board contents) ===\n")
pin_names <- pin_list(board)
cat(paste(pin_names, collapse = "\n"))
cat(sprintf("\n\nTotal pins on board: %d\n", length(pin_names)))

cat("\nDone.\n")
