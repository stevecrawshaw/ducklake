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

# ============================================================
# STEP 5: Generate datasets_catalogue
# ============================================================
cat("\n--- Step 5: Generate datasets_catalogue ---\n")

# --- View description mapping ---
# WECA-filtered views: derive from base table name
# Non-WECA views: explicit descriptions
VIEW_DESCRIPTIONS <- list(
  ca_la_lookup_inc_ns_vw = "CA/LA lookup including North Somerset",
  weca_lep_la_vw = "WECA LEP local authorities",
  ca_la_ghg_emissions_sub_sector_ods_vw = "GHG emissions by sub-sector with CA/LA lookup",
  epc_domestic_vw = "Domestic EPC certificates with derived fields"
)

#' Generate description for a view based on name pattern
get_view_description <- function(view_name) {
  # Check explicit descriptions first
  if (view_name %in% names(VIEW_DESCRIPTIONS)) {
    return(VIEW_DESCRIPTIONS[[view_name]])
  }
  # WECA-filtered views: extract base table name
  if (grepl("_weca_vw$", view_name)) {
    base_name <- sub("_weca_vw$", "_tbl", view_name)
    # Handle edge cases where _tbl suffix doesn't exist
    if (!base_name %in% tables_df$table_name) {
      base_name <- sub("_weca_vw$", "", view_name)
    }
    return(sprintf("WECA-filtered subset of %s", base_name))
  }
  return(view_name)
}

#' Extract source table name from view name
get_view_source_table <- function(view_name) {
  if (view_name == "ca_la_lookup_inc_ns_vw") return("ca_la_lookup_tbl")
  if (view_name == "weca_lep_la_vw") return("ca_la_lookup_tbl")
  if (view_name == "ca_la_ghg_emissions_sub_sector_ods_vw") return("la_ghg_emissions_tbl")
  if (view_name == "epc_domestic_vw") return("raw_domestic_epc_certificates_tbl")
  if (grepl("_weca_vw$", view_name)) {
    base_name <- sub("_weca_vw$", "_tbl", view_name)
    if (base_name %in% tables_df$table_name) return(base_name)
    return(sub("_weca_vw$", "", view_name))
  }
  return(NA_character_)
}

# --- Get view names and row counts via DuckDB CLI ---
cat("  Querying views from DuckLake...\n")

view_list_sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "INSTALL spatial; LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
          gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
  "SELECT view_name FROM duckdb_views() WHERE database_name = 'lake' ORDER BY view_name;",
  sep = "\n"
)

view_result <- run_duckdb_cli(view_list_sql, timeout = 120)

# Parse view names from CLI output
view_names <- character(0)
for (line in view_result$output) {
  cleaned <- gsub("\u2502", "|", line)
  parts <- trimws(unlist(strsplit(cleaned, "\\|")))
  parts <- parts[nchar(parts) > 0]
  if (length(parts) == 1 && grepl("_vw$", parts[1])) {
    view_names <- c(view_names, parts[1])
  }
}

cat(sprintf("  Found %d views\n", length(view_names)))

# --- Get row counts for views via DuckDB CLI ---
if (length(view_names) > 0) {
  cat("  Getting view row counts...\n")
  view_count_queries <- vapply(view_names, function(vw) {
    sprintf("SELECT '%s' AS tbl, COUNT(*) AS n FROM lake.%s", vw, vw)
  }, character(1))

  view_count_sql <- paste(
    "INSTALL ducklake; LOAD ducklake;",
    "INSTALL httpfs; LOAD httpfs;",
    "INSTALL aws; LOAD aws;",
    "INSTALL spatial; LOAD spatial;",
    "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
    sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
            gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
    paste(paste(view_count_queries, collapse = "\nUNION ALL\n"), ";"),
    sep = "\n"
  )

  view_count_result <- run_duckdb_cli(view_count_sql, timeout = 600)

  view_counts <- setNames(rep(NA_real_, length(view_names)), view_names)
  for (line in view_count_result$output) {
    cleaned <- gsub("\u2502", "|", line)
    parts <- trimws(unlist(strsplit(cleaned, "\\|")))
    parts <- parts[nchar(parts) > 0]
    if (length(parts) == 2 && parts[1] %in% view_names) {
      val <- suppressWarnings(as.numeric(parts[2]))
      if (!is.na(val)) {
        view_counts[parts[1]] <- val
      }
    }
  }
} else {
  view_counts <- numeric(0)
}

# --- Get spatial bounding boxes via DuckDB CLI ---
cat("  Computing spatial bounding boxes...\n")

spatial_tables <- SPATIAL_META$table_name
bbox_queries <- vapply(seq_len(nrow(SPATIAL_META)), function(i) {
  tbl <- SPATIAL_META$table_name[i]
  gcol <- SPATIAL_META$geom_col[i]
  sprintf(
    "SELECT '%s' AS tbl, ST_XMin(ST_Extent_Agg(%s)) AS xmin, ST_YMin(ST_Extent_Agg(%s)) AS ymin, ST_XMax(ST_Extent_Agg(%s)) AS xmax, ST_YMax(ST_Extent_Agg(%s)) AS ymax FROM lake.%s",
    tbl, gcol, gcol, gcol, gcol, tbl
  )
}, character(1))

bbox_sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "INSTALL spatial; LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
          gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
  paste(paste(bbox_queries, collapse = "\nUNION ALL\n"), ";"),
  sep = "\n"
)

bbox_result <- run_duckdb_cli(bbox_sql, timeout = 300)

# Parse bounding box results
bbox_data <- data.frame(
  table_name = character(0),
  bbox_xmin = numeric(0), bbox_ymin = numeric(0),
  bbox_xmax = numeric(0), bbox_ymax = numeric(0),
  stringsAsFactors = FALSE
)

for (line in bbox_result$output) {
  cleaned <- gsub("\u2502", "|", line)
  parts <- trimws(unlist(strsplit(cleaned, "\\|")))
  parts <- parts[nchar(parts) > 0]
  if (length(parts) == 5 && parts[1] %in% spatial_tables) {
    vals <- suppressWarnings(as.numeric(parts[2:5]))
    if (!any(is.na(vals))) {
      bbox_data <- rbind(bbox_data, data.frame(
        table_name = parts[1],
        bbox_xmin = vals[1], bbox_ymin = vals[2],
        bbox_xmax = vals[3], bbox_ymax = vals[4],
        stringsAsFactors = FALSE
      ))
    }
  }
}

# --- Build datasets_catalogue data.frame ---
cat("  Building datasets_catalogue...\n")

refresh_timestamp <- format(run_start, "%Y-%m-%d %H:%M:%S")

# Base tables rows
base_rows <- data.frame(
  name = tables_df$table_name,
  description = ifelse(is.na(tables_df$comment), "", tables_df$comment),
  type = "table",
  row_count = tables_df$source_rows,
  last_updated = refresh_timestamp,
  source_table = tables_df$table_name,
  stringsAsFactors = FALSE
)

# Add spatial metadata for base tables
base_rows$geometry_type <- NA_character_
base_rows$crs <- NA_character_
base_rows$bbox_xmin <- NA_real_
base_rows$bbox_ymin <- NA_real_
base_rows$bbox_xmax <- NA_real_
base_rows$bbox_ymax <- NA_real_

for (i in seq_len(nrow(SPATIAL_META))) {
  tbl <- SPATIAL_META$table_name[i]
  idx <- which(base_rows$name == tbl)
  if (length(idx) == 1) {
    base_rows$geometry_type[idx] <- SPATIAL_META$geom_type[i]
    base_rows$crs[idx] <- SPATIAL_META$crs[i]
    # Add bounding box if available
    bbox_idx <- which(bbox_data$table_name == tbl)
    if (length(bbox_idx) == 1) {
      base_rows$bbox_xmin[idx] <- bbox_data$bbox_xmin[bbox_idx]
      base_rows$bbox_ymin[idx] <- bbox_data$bbox_ymin[bbox_idx]
      base_rows$bbox_xmax[idx] <- bbox_data$bbox_xmax[bbox_idx]
      base_rows$bbox_ymax[idx] <- bbox_data$bbox_ymax[bbox_idx]
    }
  }
}

# View rows
if (length(view_names) > 0) {
  view_rows <- data.frame(
    name = view_names,
    description = vapply(view_names, get_view_description, character(1)),
    type = "view",
    row_count = as.numeric(view_counts[view_names]),
    last_updated = refresh_timestamp,
    source_table = vapply(view_names, get_view_source_table, character(1)),
    geometry_type = NA_character_,
    crs = NA_character_,
    bbox_xmin = NA_real_,
    bbox_ymin = NA_real_,
    bbox_xmax = NA_real_,
    bbox_ymax = NA_real_,
    stringsAsFactors = FALSE
  )
  datasets_df <- rbind(base_rows, view_rows)
} else {
  datasets_df <- base_rows
}

cat(sprintf("  datasets_catalogue: %d rows (%d tables, %d views)\n",
            nrow(datasets_df),
            sum(datasets_df$type == "table"),
            sum(datasets_df$type == "view")))

# --- Write to DuckLake via temp CSV ---
tmp_datasets_csv <- file.path(tempdir(), "datasets_catalogue.csv")
tmp_datasets_csv_sql <- gsub("\\\\", "/", tmp_datasets_csv)
write.csv(datasets_df, tmp_datasets_csv, row.names = FALSE, fileEncoding = "UTF-8")

datasets_load_sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "INSTALL spatial; LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s');",
          gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
  sprintf("CREATE OR REPLACE TABLE lake.datasets_catalogue AS SELECT * FROM read_csv('%s');",
          tmp_datasets_csv_sql),
  sep = "\n"
)

datasets_load_result <- run_duckdb_cli(datasets_load_sql, timeout = 120)
file.remove(tmp_datasets_csv)

if (datasets_load_result$exit_code != 0) {
  cat("  WARNING: Failed to load datasets_catalogue into DuckLake\n")
  for (line in datasets_load_result$output) cat(sprintf("    %s\n", line))
} else {
  cat("  datasets_catalogue loaded into DuckLake\n")
}

# --- Pin datasets_catalogue to S3 ---
cat("  Pinning datasets_catalogue to S3...\n")
pin_write(
  board,
  x = datasets_df,
  name = "datasets_catalogue",
  type = "parquet",
  title = "datasets_catalogue",
  description = sprintf("Data catalogue: %d datasets (%d tables, %d views). Generated %s",
                        nrow(datasets_df),
                        sum(datasets_df$type == "table"),
                        sum(datasets_df$type == "view"),
                        refresh_timestamp),
  metadata = list(
    source = "refresh.R catalogue generation",
    generated = refresh_timestamp
  )
)
cat("  datasets_catalogue pinned to S3\n")

# ============================================================
# STEP 6: Generate columns_catalogue
# ============================================================
cat("\n--- Step 6: Generate columns_catalogue ---\n")

# --- Use source DB column metadata (already loaded, has comments) ---
# Filter to base tables only (exclude views, exclude catalogue tables)
lake_columns <- columns_df[columns_df$table_name %in% tables_df$table_name, ]
names(lake_columns)[names(lake_columns) == "comment"] <- "description"

# Adjust data types for spatial columns: source has WKB_BLOB, DuckLake has GEOMETRY
for (i in seq_len(nrow(SPATIAL_META))) {
  gcol <- SPATIAL_META$geom_col[i]
  tbl <- SPATIAL_META$table_name[i]
  idx <- which(lake_columns$table_name == tbl & lake_columns$column_name == gcol)
  if (length(idx) == 1) {
    lake_columns$data_type[idx] <- "GEOMETRY"
  }
}

# Add geom_valid column for lsoa_2021_lep_tbl (added during spatial conversion)
lsoa_idx <- which(lake_columns$table_name == "lsoa_2021_lep_tbl")
if (length(lsoa_idx) > 0) {
  last_lsoa <- max(lsoa_idx)
  lake_columns <- rbind(
    lake_columns[1:last_lsoa, ],
    data.frame(
      table_name = "lsoa_2021_lep_tbl",
      column_name = "geom_valid",
      data_type = "BOOLEAN",
      description = "Whether the geometry is valid (ST_IsValid)",
      stringsAsFactors = FALSE
    ),
    if (last_lsoa < nrow(lake_columns)) lake_columns[(last_lsoa + 1):nrow(lake_columns), ] else NULL
  )
}

cat(sprintf("  Found %d columns across %d tables\n",
            nrow(lake_columns), length(unique(lake_columns$table_name))))

# --- Sample example values per table ---
cat("  Sampling example values...\n")

# For non-spatial tables: use R DuckDB connection (fast, no CLI parsing)
# For spatial tables: use DuckDB CLI (needs spatial extension for ST_AsText)

example_values <- data.frame(
  table_name = character(0),
  column_name = character(0),
  example_1 = character(0),
  example_2 = character(0),
  example_3 = character(0),
  stringsAsFactors = FALSE
)

unique_tables <- unique(lake_columns$table_name)

for (tbl in unique_tables) {
  tbl_cols <- lake_columns[lake_columns$table_name == tbl, ]
  is_spatial_tbl <- tbl %in% SPATIAL_META$table_name

  if (!is_spatial_tbl) {
    # --- Non-spatial: sample via R DuckDB connection ---
    for (j in seq_len(nrow(tbl_cols))) {
      col_name <- tbl_cols$column_name[j]
      col_type <- tbl_cols$data_type[j]

      if (grepl("BLOB", col_type, ignore.case = TRUE)) {
        ex <- c(NA_character_, NA_character_, NA_character_)
      } else {
        sample_q <- sprintf(
          "SELECT DISTINCT CAST(\"%s\" AS VARCHAR) AS val FROM (SELECT \"%s\" FROM \"%s\" WHERE \"%s\" IS NOT NULL LIMIT 1000) LIMIT 3",
          col_name, col_name, tbl, col_name
        )
        sample_res <- tryCatch(
          dbGetQuery(con, sample_q)$val,
          error = function(e) character(0)
        )
        ex <- c(sample_res, rep(NA_character_, 3))[1:3]
      }

      example_values <- rbind(example_values, data.frame(
        table_name = tbl, column_name = col_name,
        example_1 = ex[1], example_2 = ex[2], example_3 = ex[3],
        stringsAsFactors = FALSE
      ))
    }
  } else {
    # --- Spatial: sample via DuckDB CLI (needs spatial extension) ---
    # Build per-column queries, output to temp CSV
    tmp_sample_csv <- file.path(tempdir(), sprintf("sample_%s.csv", tbl))
    tmp_sample_csv_sql <- gsub("\\\\", "/", tmp_sample_csv)

    sample_parts <- character(0)
    for (j in seq_len(nrow(tbl_cols))) {
      col_name <- tbl_cols$column_name[j]
      col_type <- tbl_cols$data_type[j]

      if (grepl("BLOB", col_type, ignore.case = TRUE)) {
        example_values <- rbind(example_values, data.frame(
          table_name = tbl, column_name = col_name,
          example_1 = NA_character_, example_2 = NA_character_, example_3 = NA_character_,
          stringsAsFactors = FALSE
        ))
        next
      }

      if (grepl("GEOMETRY", col_type, ignore.case = TRUE)) {
        # Skip geometry example values (too large as WKT)
        example_values <- rbind(example_values, data.frame(
          table_name = tbl, column_name = col_name,
          example_1 = NA_character_, example_2 = NA_character_, example_3 = NA_character_,
          stringsAsFactors = FALSE
        ))
        next
      }

      # Handle geom_valid (only exists in DuckLake, not source DB)
      if (col_name == "geom_valid") {
        ex <- c("true", "false", NA_character_)
      } else {
        # Sample non-geometry columns from source DB
        sample_q <- sprintf(
          "SELECT DISTINCT CAST(\"%s\" AS VARCHAR) AS val FROM (SELECT \"%s\" FROM \"%s\" WHERE \"%s\" IS NOT NULL LIMIT 1000) LIMIT 3",
          col_name, col_name, tbl, col_name
        )
        sample_res <- tryCatch(
          dbGetQuery(con, sample_q)$val,
          error = function(e) character(0)
        )
        ex <- c(sample_res, rep(NA_character_, 3))[1:3]
      }

      example_values <- rbind(example_values, data.frame(
        table_name = tbl, column_name = col_name,
        example_1 = ex[1], example_2 = ex[2], example_3 = ex[3],
        stringsAsFactors = FALSE
      ))
    }
  }

  cat(sprintf("    %s: %d columns sampled\n", tbl, nrow(tbl_cols)))
}

# --- Merge column metadata with example values ---
columns_cat <- merge(lake_columns, example_values,
                     by = c("table_name", "column_name"),
                     all.x = TRUE)

# Sort by table_name, preserving column order within each table
columns_cat <- columns_cat[order(columns_cat$table_name, match(
  paste(columns_cat$table_name, columns_cat$column_name),
  paste(lake_columns$table_name, lake_columns$column_name)
)), ]

cat(sprintf("  columns_catalogue: %d rows across %d tables\n",
            nrow(columns_cat), length(unique(columns_cat$table_name))))

# --- Write to DuckLake via temp CSV ---
tmp_columns_csv <- file.path(tempdir(), "columns_catalogue.csv")
tmp_columns_csv_sql <- gsub("\\\\", "/", tmp_columns_csv)
write.csv(columns_cat, tmp_columns_csv, row.names = FALSE, fileEncoding = "UTF-8")

columns_load_sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs; LOAD httpfs;",
  "INSTALL aws; LOAD aws;",
  "INSTALL spatial; LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf("ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s');",
          gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH),
  sprintf("CREATE OR REPLACE TABLE lake.columns_catalogue AS SELECT * FROM read_csv('%s');",
          tmp_columns_csv_sql),
  sep = "\n"
)

columns_load_result <- run_duckdb_cli(columns_load_sql, timeout = 120)
file.remove(tmp_columns_csv)

if (columns_load_result$exit_code != 0) {
  cat("  WARNING: Failed to load columns_catalogue into DuckLake\n")
  for (line in columns_load_result$output) cat(sprintf("    %s\n", line))
} else {
  cat("  columns_catalogue loaded into DuckLake\n")
}

# --- Pin columns_catalogue to S3 ---
cat("  Pinning columns_catalogue to S3...\n")
pin_write(
  board,
  x = columns_cat,
  name = "columns_catalogue",
  type = "parquet",
  title = "columns_catalogue",
  description = sprintf("Column catalogue: %d columns across %d tables. Generated %s",
                        nrow(columns_cat),
                        length(unique(columns_cat$table_name)),
                        refresh_timestamp),
  metadata = list(
    source = "refresh.R catalogue generation",
    generated = refresh_timestamp
  )
)
cat("  columns_catalogue pinned to S3\n")

# ============================================================
# Final summary
# ============================================================
cat_elapsed <- as.numeric(difftime(Sys.time(), run_start, units = "secs"))
cat(sprintf("\n=== Catalogue generation complete ===\n"))
cat(sprintf("  datasets_catalogue: %d rows (%d tables, %d views)\n",
            nrow(datasets_df),
            sum(datasets_df$type == "table"),
            sum(datasets_df$type == "view")))
cat(sprintf("  columns_catalogue:  %d rows across %d tables\n",
            nrow(columns_cat),
            length(unique(columns_cat$table_name))))
cat(sprintf("  Total pipeline time: %.1f seconds\n", cat_elapsed))

cat("\nDone.\n")
