# refresh.R
# Unified refresh pipeline: re-exports all 18 tables from source DuckDB to both
# DuckLake (DROP + CREATE TABLE) and S3 pins (parquet / GeoParquet).
#
# Features:
#   - Spatial detection via column types (BLOB/GEOMETRY/WKB)
#   - Per-table edge case handling (ST_Multi, geom_valid flag)
#   - Chunked pin_upload for large tables (>5M rows)
#   - Row count validation (source vs DuckLake)
#   - Console summary table with pass/fail per table
#
# Data only -- does NOT re-apply column comments or recreate views.
#
# Usage: Rscript scripts/refresh.R
#   (run from project root directory)

library(pins)
library(duckdb)
library(DBI)
library(arrow)

# --- Configuration ---
SOURCE_DB <- "data/mca_env_base.duckdb"
DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH <- "s3://stevecrawshaw-bucket/ducklake/data/"
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
S3_REGION <- "eu-west-2"
LARGE_TABLE_THRESHOLD <- 5000000
CHUNK_SIZE <- 3000000

# --- Spatial table metadata ---
# Hardcoded; same as export_spatial_pins.R
SPATIAL_META <- data.frame(
  table_name = c(
    "bdline_ua_lep_diss_tbl",
    "bdline_ua_lep_tbl",
    "bdline_ua_weca_diss_tbl",
    "bdline_ward_lep_tbl",
    "ca_boundaries_bgc_tbl",
    "codepoint_open_lep_tbl",
    "lsoa_2021_lep_tbl",
    "open_uprn_lep_tbl"
  ),
  geom_col = c("shape", "shape", "shape", "shape", "geom", "shape", "shape", "shape"),
  geom_type = c("POLYGON", "MULTIPOLYGON", "POLYGON", "MULTIPOLYGON",
                "MULTIPOLYGON", "POINT", "MULTIPOLYGON", "POINT"),
  crs = c("EPSG:27700", "EPSG:27700", "EPSG:27700", "EPSG:27700",
          "EPSG:4326", "EPSG:27700", "EPSG:27700", "EPSG:27700"),
  stringsAsFactors = FALSE
)

# ============================================================
# Helper functions
# ============================================================

#' Build DuckLake CREATE TABLE SQL for a single table
build_ducklake_sql <- function(table_name, is_spatial, spatial_meta) {
  drop_sql <- sprintf("DROP TABLE IF EXISTS lake.%s;", table_name)

  if (!is_spatial) {
    create_sql <- sprintf(
      "CREATE TABLE lake.%s AS SELECT * FROM source.%s;",
      table_name, table_name
    )
  } else {
    meta_row <- spatial_meta[spatial_meta$table_name == table_name, ]
    geom_col <- meta_row$geom_col

    if (table_name == "ca_boundaries_bgc_tbl") {
      # Mixed POLYGON/MULTIPOLYGON -- promote all to MULTIPOLYGON
      create_sql <- sprintf(
        "CREATE TABLE lake.%s AS SELECT * EXCLUDE(%s), ST_Multi(%s) AS %s FROM source.%s;",
        table_name, geom_col, geom_col, geom_col, table_name
      )
    } else if (table_name == "lsoa_2021_lep_tbl") {
      # Invalid geometries -- add geom_valid flag
      create_sql <- sprintf(
        "CREATE TABLE lake.%s AS SELECT * EXCLUDE(%s), ST_GeomFromWKB(%s) AS %s, ST_IsValid(ST_GeomFromWKB(%s)) AS geom_valid FROM source.%s;",
        table_name, geom_col, geom_col, geom_col, geom_col, table_name
      )
    } else {
      # Standard WKB conversion
      create_sql <- sprintf(
        "CREATE TABLE lake.%s AS SELECT * EXCLUDE(%s), ST_GeomFromWKB(%s) AS %s FROM source.%s;",
        table_name, geom_col, geom_col, geom_col, table_name
      )
    }
  }

  paste(drop_sql, create_sql, sep = "\n")
}

#' Execute SQL via DuckDB CLI (write to temp file, run, clean up)
run_duckdb_cli <- function(sql_text, timeout = 600) {
  tmp_sql <- "scripts/.tmp_refresh.sql"
  writeLines(sql_text, tmp_sql, useBytes = TRUE)
  cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql)
  result <- system(cmd, intern = TRUE, timeout = timeout)
  file.remove(tmp_sql)
  exit_code <- attr(result, "status")
  list(
    output = result,
    exit_code = if (is.null(exit_code)) 0L else exit_code
  )
}

#' Get row counts from DuckLake for all tables via a single CLI call
#' Returns named numeric vector: table_name -> row_count
get_ducklake_counts <- function(table_names) {
  # Build a UNION ALL query that returns table_name, row_count pairs
  count_queries <- vapply(table_names, function(tbl) {
    sprintf("SELECT '%s' AS tbl, COUNT(*) AS n FROM lake.%s", tbl, tbl)
  }, character(1))

  combined_query <- paste(count_queries, collapse = "\nUNION ALL\n")

  sql <- paste(
    "INSTALL ducklake; LOAD ducklake;",
    "INSTALL httpfs; LOAD httpfs;",
    "INSTALL aws; LOAD aws;",
    "INSTALL spatial; LOAD spatial;",
    "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
    sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
            gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
    paste0(combined_query, ";"),
    sep = "\n"
  )
  result <- run_duckdb_cli(sql, timeout = 300)

  # Parse box-drawing table output from DuckDB CLI
  # Lines with data look like: │ table_name │ 12345 │
  counts <- setNames(rep(NA_real_, length(table_names)), table_names)
  for (line in result$output) {
    # Match lines containing a table name and a number separated by │
    cleaned <- gsub("\u2502", "|", line)  # Replace box-drawing │ with |
    parts <- trimws(unlist(strsplit(cleaned, "\\|")))
    parts <- parts[nchar(parts) > 0]
    if (length(parts) == 2 && parts[1] %in% table_names) {
      val <- suppressWarnings(as.numeric(parts[2]))
      if (!is.na(val)) {
        counts[parts[1]] <- val
      }
    }
  }

  counts
}

#' Export a non-spatial table as a pin
export_nonspatial_pin <- function(con, board, table_name, row_count, col_meta) {
  title <- table_name
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

  is_large <- row_count > LARGE_TABLE_THRESHOLD

  if (is_large) {
    # Chunked pin_upload for large tables
    n_chunks <- ceiling(row_count / CHUNK_SIZE)
    temp_paths <- character(n_chunks)

    for (chunk_i in seq_len(n_chunks)) {
      offset <- (chunk_i - 1) * CHUNK_SIZE
      chunk_file <- file.path(
        tempdir(),
        sprintf("%s_part%03d.parquet", table_name, chunk_i)
      )
      temp_paths[chunk_i] <- chunk_file

      dbExecute(con, sprintf(
        "COPY (SELECT * FROM \"%s\" LIMIT %d OFFSET %d) TO '%s' (FORMAT PARQUET, ROW_GROUP_SIZE 100000)",
        table_name, CHUNK_SIZE, offset,
        gsub("\\\\", "/", chunk_file)
      ))
    }

    pin_upload(
      board,
      paths = temp_paths,
      name = table_name,
      title = title,
      description = sprintf("%s (%s rows, %d columns, %d parquet files)",
                            title, format(row_count, big.mark = ","),
                            nrow(col_meta), n_chunks),
      metadata = meta
    )

    unlink(temp_paths)
  } else {
    # Standard pin_write
    df <- dbReadTable(con, table_name)

    pin_write(
      board,
      x = df,
      name = table_name,
      type = "parquet",
      title = title,
      description = sprintf("%s (%s rows, %d columns)",
                            title, format(row_count, big.mark = ","),
                            nrow(col_meta)),
      metadata = meta
    )

    rm(df)
  }
}

#' Export a spatial table as a GeoParquet pin
export_spatial_pin <- function(board, table_name, spatial_meta) {
  meta_row <- spatial_meta[spatial_meta$table_name == table_name, ]
  geom_col <- meta_row$geom_col
  geom_type <- meta_row$geom_type
  crs <- meta_row$crs

  temp_path <- file.path(tempdir(), sprintf("tmp_%s.parquet", table_name))
  temp_path_sql <- gsub("\\\\", "/", temp_path)

  # Build per-table SELECT with geometry conversion
  if (table_name == "ca_boundaries_bgc_tbl") {
    select_sql <- sprintf(
      "SELECT * EXCLUDE(%s), ST_Multi(%s) AS %s FROM source.%s",
      geom_col, geom_col, geom_col, table_name
    )
  } else if (table_name == "lsoa_2021_lep_tbl") {
    select_sql <- sprintf(
      "SELECT * EXCLUDE(%s), ST_GeomFromWKB(%s) AS %s, ST_IsValid(ST_GeomFromWKB(%s)) AS geom_valid FROM source.%s",
      geom_col, geom_col, geom_col, geom_col, table_name
    )
  } else {
    select_sql <- sprintf(
      "SELECT * EXCLUDE(%s), ST_GeomFromWKB(%s) AS %s FROM source.%s",
      geom_col, geom_col, geom_col, table_name
    )
  }

  sql <- paste(
    "INSTALL spatial; LOAD spatial;",
    sprintf("ATTACH '%s' AS source (READ_ONLY);",
            gsub("\\\\", "/", SOURCE_DB)),
    sprintf("COPY (%s) TO '%s' (FORMAT PARQUET);", select_sql, temp_path_sql),
    sep = "\n"
  )

  result <- run_duckdb_cli(sql, timeout = 600)

  if (result$exit_code != 0 || !file.exists(temp_path)) {
    stop(sprintf("GeoParquet export failed for %s", table_name))
  }

  pin_upload(
    board,
    paths = temp_path,
    name = table_name,
    title = table_name,
    description = sprintf("%s (GeoParquet, %s, %s)", table_name, geom_type, crs),
    metadata = list(
      source_db = "ducklake",
      spatial = TRUE,
      geometry_column = geom_col,
      geometry_type = geom_type,
      crs = crs
    )
  )

  unlink(temp_path)
}


# ============================================================
# MAIN
# ============================================================

run_start <- Sys.time()

cat("=== DuckLake Refresh Pipeline ===\n")
cat(sprintf("Source:    %s\n", SOURCE_DB))
cat(sprintf("DuckLake:  %s\n", DUCKLAKE_FILE))
cat(sprintf("Pins:      s3://%s/%s\n", S3_BUCKET, S3_PREFIX))
cat(sprintf("Started:   %s\n\n", format(run_start, "%Y-%m-%d %H:%M:%S")))

# --- Connect to source DuckDB ---
con <- dbConnect(duckdb(), dbdir = SOURCE_DB, read_only = TRUE)
on.exit(dbDisconnect(con, shutdown = TRUE), add = TRUE)

# --- Get all tables ---
tables_df <- dbGetQuery(con, "
  SELECT table_name, comment, estimated_size, column_count
  FROM duckdb_tables()
  WHERE schema_name = 'main' AND internal = false
  ORDER BY table_name
")

# --- Get all column metadata ---
columns_df <- dbGetQuery(con, "
  SELECT table_name, column_name, data_type, comment
  FROM duckdb_columns()
  WHERE schema_name = 'main'
  ORDER BY table_name, column_index
")

# --- Classify spatial vs non-spatial ---
spatial_cols <- columns_df[
  grepl("BLOB|GEOMETRY|WKB", columns_df$data_type, ignore.case = TRUE),
]
spatial_table_names <- unique(spatial_cols$table_name)

tables_df$is_spatial <- tables_df$table_name %in% spatial_table_names

cat(sprintf("Tables: %d total (%d non-spatial, %d spatial)\n\n",
            nrow(tables_df),
            sum(!tables_df$is_spatial),
            sum(tables_df$is_spatial)))

# --- Get source row counts ---
tables_df$source_rows <- vapply(
  tables_df$table_name,
  function(tbl) {
    dbGetQuery(con, sprintf('SELECT COUNT(*) AS n FROM "%s"', tbl))$n
  },
  numeric(1)
)

# ============================================================
# STEP 1: DuckLake export (single CLI call for all 18 tables)
# ============================================================
cat("--- Step 1: DuckLake export (DROP + CREATE for all tables) ---\n")

ducklake_header <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "INSTALL spatial; LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s');",
          gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
  sprintf("ATTACH '%s' AS source (READ_ONLY);",
          gsub("\\\\", "/", SOURCE_DB)),
  "",
  sep = "\n"
)

# Build all DROP + CREATE statements
ducklake_stmts <- vapply(
  seq_len(nrow(tables_df)),
  function(i) {
    build_ducklake_sql(
      tables_df$table_name[i],
      tables_df$is_spatial[i],
      SPATIAL_META
    )
  },
  character(1)
)

ducklake_sql <- paste(ducklake_header, paste(ducklake_stmts, collapse = "\n\n"), sep = "\n")

cat("Executing DuckLake DROP + CREATE for all 18 tables...\n")
ducklake_start <- Sys.time()
ducklake_result <- run_duckdb_cli(ducklake_sql, timeout = 1800)
ducklake_elapsed <- as.numeric(difftime(Sys.time(), ducklake_start, units = "secs"))

if (ducklake_result$exit_code != 0) {
  cat(sprintf("WARNING: DuckDB CLI exited with code %d\n", ducklake_result$exit_code))
  cat("Output:\n")
  for (line in ducklake_result$output) cat(sprintf("  %s\n", line))
} else {
  cat(sprintf("DuckLake export complete (%.1f seconds)\n", ducklake_elapsed))
}

cat("\n")

# ============================================================
# STEP 2: Validate DuckLake row counts
# ============================================================
cat("--- Step 2: Validate DuckLake row counts ---\n")

tables_df$ducklake_rows <- NA_real_
tables_df$ducklake_ok <- FALSE

lake_counts <- get_ducklake_counts(tables_df$table_name)

for (i in seq_len(nrow(tables_df))) {
  tbl <- tables_df$table_name[i]
  lake_count <- lake_counts[tbl]
  tables_df$ducklake_rows[i] <- lake_count

  if (!is.na(lake_count) && lake_count == tables_df$source_rows[i]) {
    tables_df$ducklake_ok[i] <- TRUE
    cat(sprintf("  %s: %s rows -- MATCH\n", tbl, format(lake_count, big.mark = ",")))
  } else {
    cat(sprintf("  %s: source=%s, lake=%s -- MISMATCH\n",
                tbl,
                format(tables_df$source_rows[i], big.mark = ","),
                if (is.na(lake_count)) "NA" else format(lake_count, big.mark = ",")))
  }
}

cat(sprintf("\nDuckLake validation: %d/%d tables match\n\n",
            sum(tables_df$ducklake_ok), nrow(tables_df)))

# ============================================================
# STEP 3: Pin export (per-table)
# ============================================================
cat("--- Step 3: Pin export ---\n")

board <- board_s3(
  bucket = S3_BUCKET,
  prefix = S3_PREFIX,
  region = S3_REGION,
  versioned = TRUE
)

# Results tracking
tables_df$pin_ok <- FALSE
tables_df$pin_error <- NA_character_
tables_df$time_secs <- NA_real_

for (i in seq_len(nrow(tables_df))) {
  tbl <- tables_df$table_name[i]
  is_spatial <- tables_df$is_spatial[i]
  row_count <- tables_df$source_rows[i]

  method <- if (is_spatial) {
    "geoparquet"
  } else if (row_count > LARGE_TABLE_THRESHOLD) {
    "chunked"
  } else {
    "pin_write"
  }

  cat(sprintf("[%d/%d] %s (%s rows) [%s]... ",
              i, nrow(tables_df), tbl,
              format(row_count, big.mark = ","), method))

  tbl_start <- Sys.time()

  result <- tryCatch({
    if (is_spatial) {
      export_spatial_pin(board, tbl, SPATIAL_META)
    } else {
      col_meta <- columns_df[columns_df$table_name == tbl, ]
      export_nonspatial_pin(con, board, tbl, row_count, col_meta)
    }
    list(success = TRUE, error = NULL)
  }, error = function(e) {
    list(success = FALSE, error = conditionMessage(e))
  })

  tbl_elapsed <- as.numeric(difftime(Sys.time(), tbl_start, units = "secs"))
  tables_df$time_secs[i] <- tbl_elapsed
  tables_df$pin_ok[i] <- result$success
  if (!result$success) tables_df$pin_error[i] <- result$error

  if (result$success) {
    cat(sprintf("OK (%.1fs)\n", tbl_elapsed))
  } else {
    cat(sprintf("FAILED: %s\n", result$error))
  }
}

cat("\n")

# ============================================================
# STEP 4: Console summary
# ============================================================
run_elapsed <- as.numeric(difftime(Sys.time(), run_start, units = "secs"))

# Determine overall pass/fail per table
tables_df$status <- ifelse(tables_df$ducklake_ok & tables_df$pin_ok, "PASS", "FAIL")

cat("=== Refresh Summary ===\n\n")
cat(sprintf("%-35s %10s %8s %6s\n", "Table", "Rows", "Secs", "Status"))
cat(paste(rep("-", 65), collapse = ""), "\n")

for (i in seq_len(nrow(tables_df))) {
  cat(sprintf("%-35s %10s %8.1f %6s\n",
              tables_df$table_name[i],
              format(tables_df$source_rows[i], big.mark = ","),
              tables_df$time_secs[i],
              tables_df$status[i]))
}

cat(paste(rep("-", 65), collapse = ""), "\n")

n_pass <- sum(tables_df$status == "PASS")
n_fail <- sum(tables_df$status == "FAIL")
total_rows <- sum(tables_df$source_rows)

cat(sprintf("\nTables refreshed: %d/%d\n", n_pass, nrow(tables_df)))
cat(sprintf("Total rows:       %s\n", format(total_rows, big.mark = ",")))
cat(sprintf("Total time:       %.1f seconds\n", run_elapsed))
cat(sprintf("Failures:         %d\n", n_fail))

if (n_fail > 0) {
  cat("\n--- Failure Details ---\n")
  failed <- tables_df[tables_df$status == "FAIL", ]
  for (j in seq_len(nrow(failed))) {
    reason <- if (!failed$ducklake_ok[j]) "DuckLake row count mismatch"
              else if (!failed$pin_ok[j]) failed$pin_error[j]
              else "Unknown"
    cat(sprintf("  %s: %s\n", failed$table_name[j], reason))
  }
}

cat(sprintf("\nOverall: %s\n", if (n_fail == 0) "ALL PASSED" else "SOME FAILED"))
cat("\nDone.\n")
