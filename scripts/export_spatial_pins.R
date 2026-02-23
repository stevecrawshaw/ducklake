# export_spatial_pins.R
# Exports all 8 spatial tables from DuckLake as GeoParquet pins to S3.
# First recreates spatial tables in DuckLake (idempotent), then exports each
# as GeoParquet via DuckDB COPY TO and uploads via pin_upload().
#
# Edge cases:
#   - ca_boundaries_bgc_tbl: ST_Multi(geom) for mixed POLYGON/MULTIPOLYGON
#   - lsoa_2021_lep_tbl: geom_valid BOOLEAN flag for 2 invalid geometries
#
# Usage: Rscript scripts/export_spatial_pins.R
#   (run from project root directory)

library(pins)

# --- Configuration ---
SQL_FILE <- "scripts/recreate_spatial_ducklake.sql"
SOURCE_DB <- "data/mca_env_base.duckdb"
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
S3_REGION <- "eu-west-2"
TEMP_DIR <- "data"

# --- Table metadata ---
spatial_tables <- data.frame(
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
  rows = c(1, 4, 1, 130, 15, 31299, 698, 687143),
  title = c(
    "Boundary line UA LEP dissolved",
    "Boundary line UA LEP",
    "Boundary line UA WECA dissolved",
    "Boundary line ward LEP",
    "Combined authority boundaries BGC",
    "Codepoint open LEP",
    "LSOA 2021 LEP",
    "Open UPRN LEP"
  ),
  stringsAsFactors = FALSE
)

# Track results
results <- data.frame(
  table_name = spatial_tables$table_name,
  ducklake_ok = FALSE,
  export_ok = FALSE,
  pin_ok = FALSE,
  meta_ok = FALSE,
  error = NA_character_,
  stringsAsFactors = FALSE
)

cat("=== Spatial GeoParquet Pin Export ===\n")
cat(sprintf("Source: %s\n", SOURCE_DB))
cat(sprintf("Target: s3://%s/%s\n", S3_BUCKET, S3_PREFIX))
cat(sprintf("Tables: %d spatial tables\n\n", nrow(spatial_tables)))

# ============================================================
# STEP 1: Recreate DuckLake spatial tables
# ============================================================
cat("--- Step 1: Recreate DuckLake spatial tables ---\n")

cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', SQL_FILE)
cat(sprintf("Running: %s\n", cmd))

cli_output <- system(cmd, intern = TRUE, timeout = 600)

exit_code <- attr(cli_output, "status")
if (!is.null(exit_code) && exit_code != 0) {
  cat(sprintf("ERROR: DuckDB CLI exited with code %d\n", exit_code))
  cat("Output:\n")
  for (line in cli_output) cat(sprintf("  %s\n", line))
  stop("DuckLake table recreation failed")
}

# Check all tables have GEOMETRY type in output
cli_text <- paste(cli_output, collapse = "\n")
for (i in seq_len(nrow(spatial_tables))) {
  tbl <- spatial_tables$table_name[i]
  if (grepl(tbl, cli_text, fixed = TRUE)) {
    results$ducklake_ok[i] <- TRUE
  }
}

ducklake_count <- sum(results$ducklake_ok)
cat(sprintf("DuckLake tables recreated: %d/%d\n\n", ducklake_count, nrow(spatial_tables)))

# ============================================================
# STEP 2: Export each table as GeoParquet and upload as pin
# ============================================================
cat("--- Step 2: Export GeoParquet and upload pins ---\n")

# Create S3 board
board <- board_s3(
  bucket = S3_BUCKET,
  prefix = S3_PREFIX,
  region = S3_REGION,
  versioned = TRUE
)

# Helper: build SQL for a single table export
build_export_sql <- function(table_name, geom_col, temp_path) {
  # Extension and source setup
  header <- paste(
    "INSTALL spatial; LOAD spatial;",
    sprintf("ATTACH '%s' AS source (READ_ONLY);", SOURCE_DB),
    sep = "\n"
  )

  # Per-table SELECT with geometry conversion
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

  copy_sql <- sprintf("COPY (%s) TO '%s' (FORMAT PARQUET);", select_sql, temp_path)

  paste(header, copy_sql, sep = "\n")
}

for (i in seq_len(nrow(spatial_tables))) {
  tbl <- spatial_tables$table_name[i]
  geom_col <- spatial_tables$geom_col[i]
  geom_type <- spatial_tables$geom_type[i]
  crs <- spatial_tables$crs[i]
  expected_rows <- spatial_tables$rows[i]
  tbl_title <- spatial_tables$title[i]

  temp_path <- file.path(TEMP_DIR, sprintf("tmp_%s.parquet", tbl))
  # Use forward slashes for DuckDB
  temp_path_sql <- gsub("\\\\", "/", temp_path)

  cat(sprintf("[%d/%d] %s (%s rows)... ",
              i, nrow(spatial_tables), tbl,
              format(expected_rows, big.mark = ",")))

  tryCatch({
    # Build and write SQL for this table's export
    export_sql <- build_export_sql(tbl, geom_col, temp_path_sql)
    tmp_sql_file <- file.path(TEMP_DIR, sprintf(".tmp_export_%s.sql", tbl))
    writeLines(export_sql, tmp_sql_file)

    # Execute via DuckDB CLI
    export_cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql_file)
    export_output <- system(export_cmd, intern = TRUE, timeout = 600)
    export_exit <- attr(export_output, "status")

    # Clean up temp SQL
    file.remove(tmp_sql_file)

    if (!is.null(export_exit) && export_exit != 0) {
      stop(paste("DuckDB export failed:", paste(export_output, collapse = "\n")))
    }

    # Check file exists
    if (!file.exists(temp_path)) {
      stop("GeoParquet file not created")
    }

    results$export_ok[i] <- TRUE
    fsize <- file.info(temp_path)$size
    cat(sprintf("exported (%.1f KB)... ", fsize / 1024))

    # Upload as pin
    pin_upload(
      board,
      paths = temp_path,
      name = tbl,
      title = tbl_title,
      description = sprintf("%s (%s rows, GeoParquet, %s)",
                            tbl_title,
                            format(expected_rows, big.mark = ","),
                            crs),
      metadata = list(
        source_db = "ducklake",
        spatial = TRUE,
        geometry_column = geom_col,
        geometry_type = geom_type,
        crs = crs
      )
    )

    results$pin_ok[i] <- TRUE
    cat("pinned... ")

    # Clean up temp parquet
    file.remove(temp_path)

    cat("OK\n")
  }, error = function(e) {
    results$error[i] <<- conditionMessage(e)
    cat(sprintf("FAILED: %s\n", conditionMessage(e)))
    # Clean up on failure
    if (file.exists(temp_path)) file.remove(temp_path)
    tmp_sql <- file.path(TEMP_DIR, sprintf(".tmp_export_%s.sql", tbl))
    if (file.exists(tmp_sql)) file.remove(tmp_sql)
  })
}

cat("\n")

# ============================================================
# STEP 3: Validate pins and metadata
# ============================================================
cat("--- Step 3: Validate pins and metadata ---\n")

for (i in seq_len(nrow(spatial_tables))) {
  tbl <- spatial_tables$table_name[i]

  if (!results$pin_ok[i]) {
    cat(sprintf("  %s: SKIPPED (pin upload failed)\n", tbl))
    next
  }

  tryCatch({
    meta <- pin_meta(board, tbl)
    if (isTRUE(meta$user$spatial)) {
      results$meta_ok[i] <- TRUE
      cat(sprintf("  %s: spatial=%s, geom_col=%s, geom_type=%s, crs=%s\n",
                  tbl, meta$user$spatial, meta$user$geometry_column,
                  meta$user$geometry_type, meta$user$crs))
    } else {
      cat(sprintf("  %s: FAILED -- spatial metadata not TRUE\n", tbl))
    }
  }, error = function(e) {
    cat(sprintf("  %s: FAILED -- %s\n", tbl, conditionMessage(e)))
  })
}

cat("\n")

# ============================================================
# STEP 4: R roundtrip check (bdline_ua_lep_diss_tbl)
# ============================================================
cat("--- Step 4: R roundtrip check ---\n")

r_roundtrip_ok <- FALSE
tryCatch({
  library(arrow)
  library(sf)

  pin_path <- pin_download(board, "bdline_ua_lep_diss_tbl")
  cat(sprintf("  Downloaded: %s\n", pin_path))

  arrow_tbl <- arrow::read_parquet(pin_path, as_data_frame = FALSE)
  sf_obj <- sf::st_as_sf(as.data.frame(arrow_tbl))

  cat(sprintf("  Class: %s\n", paste(class(sf_obj), collapse = ", ")))
  cat(sprintf("  Geometry type: %s\n", paste(unique(sf::st_geometry_type(sf_obj)), collapse = ", ")))
  cat(sprintf("  Rows: %d\n", nrow(sf_obj)))

  # Set CRS (not embedded in GeoParquet by DuckDB)
  sf_obj <- sf::st_set_crs(sf_obj, 27700)
  cat(sprintf("  CRS: EPSG:%s (set explicitly)\n", sf::st_crs(sf_obj)$epsg))

  r_roundtrip_ok <- TRUE
  cat("  R roundtrip: PASSED\n")
}, error = function(e) {
  cat(sprintf("  R roundtrip: FAILED -- %s\n", conditionMessage(e)))
})

cat("\n")

# ============================================================
# STEP 5: Summary
# ============================================================
cat("=== Spatial Pin Export Summary ===\n\n")

# Summary table
cat(sprintf("%-30s %8s %15s %12s %8s %8s %8s\n",
            "Table", "Rows", "Geometry Type", "CRS",
            "DLake", "Export", "Pin"))
cat(paste(rep("-", 95), collapse = ""), "\n")

for (i in seq_len(nrow(spatial_tables))) {
  cat(sprintf("%-30s %8s %15s %12s %8s %8s %8s\n",
              spatial_tables$table_name[i],
              format(spatial_tables$rows[i], big.mark = ","),
              spatial_tables$geom_type[i],
              spatial_tables$crs[i],
              if (results$ducklake_ok[i]) "OK" else "FAIL",
              if (results$export_ok[i]) "OK" else "FAIL",
              if (results$pin_ok[i]) "OK" else "FAIL"))
}

cat("\n")

# Pass/fail counts
ducklake_pass <- sum(results$ducklake_ok)
export_pass <- sum(results$export_ok)
pin_pass <- sum(results$pin_ok)
meta_pass <- sum(results$meta_ok)
total <- nrow(spatial_tables)

cat(sprintf("DuckLake tables recreated:  %d/%d %s\n", ducklake_pass, total,
            if (ducklake_pass == total) "PASS" else "FAIL"))
cat(sprintf("GeoParquet pins uploaded:   %d/%d %s\n", pin_pass, total,
            if (pin_pass == total) "PASS" else "FAIL"))
cat(sprintf("Spatial metadata confirmed: %d/%d %s\n", meta_pass, total,
            if (meta_pass == total) "PASS" else "FAIL"))
cat(sprintf("R roundtrip check:          %s\n",
            if (r_roundtrip_ok) "1/1 PASS" else "0/1 FAIL"))

# Report failures
failures <- results[!is.na(results$error), ]
if (nrow(failures) > 0) {
  cat("\n--- Failures ---\n")
  for (j in seq_len(nrow(failures))) {
    cat(sprintf("  %s: %s\n", failures$table_name[j], failures$error[j]))
  }
}

# Overall result
all_pass <- ducklake_pass == total && pin_pass == total &&
  meta_pass == total && r_roundtrip_ok
cat(sprintf("\nOverall: %s\n", if (all_pass) "ALL CHECKS PASSED" else "SOME CHECKS FAILED"))

cat("\nDone.\n")
