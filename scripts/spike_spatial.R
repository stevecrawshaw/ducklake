# spike_spatial.R
# Spike: Full spatial pipeline validation with bdline_ua_lep_diss_tbl (1 row).
# Steps:
#   1. DuckDB CLI executes SQL (GEOMETRY recreation, spatial SQL, GeoParquet export)
#   2. Upload GeoParquet as pin to S3
#   3. Validate R roundtrip (sf object)
#   4. Validate Python roundtrip (GeoDataFrame)
#   5. Clean up and summarise
#
# Usage: Rscript scripts/spike_spatial.R
#   (run from project root directory)

library(pins)

# --- Configuration ---
SQL_FILE <- "scripts/spike_spatial.sql"
GEOPARQUET_FILE <- "data/tmp_spike_spatial.parquet"
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
S3_REGION <- "eu-west-2"
PIN_NAME <- "bdline_ua_lep_diss_tbl"

# Track results for final summary
results <- list(
  duckdb_cli = FALSE,
  geometry_type = FALSE,
  spatial_sql = FALSE,
  geoparquet_export = FALSE,
  pin_upload = FALSE,
  r_roundtrip = FALSE,
  python_roundtrip = FALSE
)

cat("=== Spatial Pipeline Spike ===\n")
cat(sprintf("Table: %s (1 row, simplest spatial table)\n", PIN_NAME))
cat(sprintf("SQL:   %s\n", SQL_FILE))
cat(sprintf("Pin:   s3://%s/%s%s\n\n", S3_BUCKET, S3_PREFIX, PIN_NAME))

# ============================================================
# STEP 1: Execute SQL via DuckDB CLI
# ============================================================
cat("--- Step 1: DuckDB CLI execution ---\n")

cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', SQL_FILE)
cat(sprintf("Running: %s\n", cmd))

cli_output <- system(cmd, intern = TRUE, timeout = 300)

# Print output
if (length(cli_output) > 0) {
  for (line in cli_output) {
    cat(sprintf("  %s\n", line))
  }
}

exit_code <- attr(cli_output, "status")
if (!is.null(exit_code) && exit_code != 0) {
  cat(sprintf("ERROR: DuckDB CLI exited with code %d\n", exit_code))
} else {
  results$duckdb_cli <- TRUE
  cat("DuckDB CLI: OK\n")
}

# Parse output for verification checks
cli_text <- paste(cli_output, collapse = "\n")

# Check GEOMETRY type
if (grepl("GEOMETRY", cli_text, fixed = TRUE) && !grepl("BLOB", cli_text, fixed = TRUE)) {
  results$geometry_type <- TRUE
  cat("GEOMETRY type check: PASSED (native GEOMETRY, not BLOB)\n")
} else {
  # More nuanced check -- look for the test result line
  if (grepl("GEOMETRY_TYPE_CHECK", cli_text, fixed = TRUE)) {
    # Extract the result value after GEOMETRY_TYPE_CHECK
    type_match <- regmatches(cli_text, regexpr("GEOMETRY_TYPE_CHECK[^\\n]*GEOMETRY", cli_text))
    if (length(type_match) > 0) {
      results$geometry_type <- TRUE
      cat("GEOMETRY type check: PASSED\n")
    } else {
      cat("GEOMETRY type check: FAILED (could not confirm GEOMETRY type)\n")
    }
  } else {
    cat("GEOMETRY type check: INCONCLUSIVE (check output above)\n")
  }
}

# Check spatial SQL (ST_Area non-zero)
if (grepl("SPATIAL_SQL_CHECK", cli_text, fixed = TRUE)) {
  # Look for a non-zero numeric value
  area_match <- regmatches(cli_text, gregexpr("[0-9]+\\.[0-9]+", cli_text))[[1]]
  if (length(area_match) > 0 && any(as.numeric(area_match) > 0)) {
    results$spatial_sql <- TRUE
    cat(sprintf("Spatial SQL check: PASSED (area values found: %s)\n",
                paste(area_match[as.numeric(area_match) > 0], collapse = ", ")))
  } else {
    cat("Spatial SQL check: FAILED (no non-zero area found)\n")
  }
} else {
  cat("Spatial SQL check: INCONCLUSIVE\n")
}

# Check GeoParquet export
if (file.exists(GEOPARQUET_FILE)) {
  fsize <- file.info(GEOPARQUET_FILE)$size
  results$geoparquet_export <- TRUE
  cat(sprintf("GeoParquet export: PASSED (%s, %.1f KB)\n", GEOPARQUET_FILE, fsize / 1024))
} else {
  cat("GeoParquet export: FAILED (file not created)\n")
}

# Check GeoParquet metadata
if (grepl("GEOPARQUET_META_CHECK", cli_text, fixed = TRUE) && grepl("geo", cli_text, fixed = TRUE)) {
  cat("GeoParquet metadata: geo key found in parquet metadata\n")
} else {
  cat("GeoParquet metadata: WARNING -- geo key not detected in output (may still be present)\n")
}

cat("\n")

# ============================================================
# STEP 2: Upload GeoParquet as pin
# ============================================================
cat("--- Step 2: Pin upload ---\n")

if (!results$geoparquet_export) {
  cat("SKIPPED: GeoParquet file not available\n\n")
} else {
  tryCatch({
    board <- board_s3(
      bucket = S3_BUCKET,
      prefix = S3_PREFIX,
      region = S3_REGION,
      versioned = TRUE
    )

    pin_upload(
      board,
      paths = GEOPARQUET_FILE,
      name = PIN_NAME,
      title = "Boundary line UA LEP dissolved",
      description = "Boundary line UA LEP dissolved (1 row, 3 columns, GeoParquet, EPSG:27700)",
      metadata = list(
        source_db = "ducklake",
        spatial = TRUE,
        geometry_column = "shape",
        geometry_type = "POLYGON",
        crs = "EPSG:27700"
      )
    )

    results$pin_upload <- TRUE
    cat("Pin upload: OK\n")

    # Verify metadata
    meta <- pin_meta(board, PIN_NAME)
    cat(sprintf("  Pin title: %s\n", meta$title))
    cat(sprintf("  Pin spatial: %s\n", meta$user$spatial))
    cat(sprintf("  Pin CRS: %s\n", meta$user$crs))
  }, error = function(e) {
    cat(sprintf("Pin upload: FAILED -- %s\n", conditionMessage(e)))
  })
  cat("\n")
}

# ============================================================
# STEP 3: R roundtrip validation
# ============================================================
cat("--- Step 3: R roundtrip validation ---\n")

if (!results$pin_upload) {
  cat("SKIPPED: Pin not uploaded\n\n")
} else {
  tryCatch({
    # Download pin
    pin_path <- pin_download(board, PIN_NAME)
    cat(sprintf("  Downloaded: %s\n", pin_path))

    # Try sfarrow first
    sf_obj <- NULL
    read_method <- NULL

    tryCatch({
      library(sfarrow)
      sf_obj <- sfarrow::st_read_parquet(pin_path)
      read_method <- "sfarrow::st_read_parquet"
      cat(sprintf("  Read method: %s (success)\n", read_method))
    }, error = function(e) {
      cat(sprintf("  sfarrow failed: %s\n", conditionMessage(e)))
      cat("  Trying arrow::read_parquet fallback...\n")
    })

    # Fallback to arrow + sf if sfarrow failed
    if (is.null(sf_obj)) {
      tryCatch({
        library(arrow)
        library(sf)
        arrow_tbl <- arrow::read_parquet(pin_path, as_data_frame = FALSE)
        sf_obj <- sf::st_as_sf(as.data.frame(arrow_tbl))
        read_method <- "arrow::read_parquet + sf::st_as_sf"
        cat(sprintf("  Read method: %s (success)\n", read_method))
      }, error = function(e) {
        cat(sprintf("  arrow fallback also failed: %s\n", conditionMessage(e)))
      })
    }

    if (!is.null(sf_obj)) {
      library(sf)

      cat(sprintf("  Class: %s\n", paste(class(sf_obj), collapse = ", ")))
      cat(sprintf("  Geometry type: %s\n", paste(unique(sf::st_geometry_type(sf_obj)), collapse = ", ")))
      cat(sprintf("  Rows: %d\n", nrow(sf_obj)))

      # Check CRS
      crs <- sf::st_crs(sf_obj)
      if (is.na(crs) || is.null(crs$epsg)) {
        cat("  CRS: NA (expected -- DuckDB COPY TO does not write CRS into GeoParquet)\n")
        cat("  Setting CRS to EPSG:27700...\n")
        sf_obj <- sf::st_set_crs(sf_obj, 27700)
        crs <- sf::st_crs(sf_obj)
        cat(sprintf("  CRS after set: EPSG:%s\n", crs$epsg))
      } else {
        cat(sprintf("  CRS: EPSG:%s\n", crs$epsg))
      }

      results$r_roundtrip <- TRUE
      cat("R roundtrip: PASSED\n")
    } else {
      cat("R roundtrip: FAILED (could not read as sf)\n")
    }
  }, error = function(e) {
    cat(sprintf("R roundtrip: FAILED -- %s\n", conditionMessage(e)))
  })
  cat("\n")
}

# ============================================================
# STEP 4: Python roundtrip validation
# ============================================================
cat("--- Step 4: Python roundtrip validation ---\n")

if (!results$pin_upload) {
  cat("SKIPPED: Pin not uploaded\n\n")
} else {
  tryCatch({
    # Write Python validation script
    py_script <- 'scripts/.tmp_validate_spatial.py'
    py_code <- sprintf('
import os
import sys
os.environ.setdefault("AWS_DEFAULT_REGION", "%s")
try:
    from pins import board_s3
    import geopandas as gpd

    board = board_s3("%s/pins", versioned=True)
    path = board.pin_download("%s")
    gdf = gpd.read_parquet(path[0])

    print(f"Type: {type(gdf).__name__}")
    print(f"Geometry type: {gdf.geometry.geom_type.unique().tolist()}")
    print(f"CRS: {gdf.crs}")
    print(f"Rows: {len(gdf)}")
    print("PYTHON_ROUNDTRIP_OK")
except Exception as e:
    print(f"PYTHON_ROUNDTRIP_FAILED: {e}")
    sys.exit(1)
', S3_REGION, S3_BUCKET, PIN_NAME)

    writeLines(py_code, py_script)

    py_output <- system("uv run python scripts/.tmp_validate_spatial.py",
                        intern = TRUE, timeout = 120)

    for (line in py_output) {
      cat(sprintf("  %s\n", line))
    }

    py_exit <- attr(py_output, "status")
    py_text <- paste(py_output, collapse = "\n")

    if (grepl("PYTHON_ROUNDTRIP_OK", py_text, fixed = TRUE)) {
      results$python_roundtrip <- TRUE
      cat("Python roundtrip: PASSED\n")
    } else {
      cat("Python roundtrip: FAILED\n")
    }

    # Clean up
    file.remove(py_script)
  }, error = function(e) {
    cat(sprintf("Python roundtrip: FAILED -- %s\n", conditionMessage(e)))
    if (file.exists("scripts/.tmp_validate_spatial.py")) {
      file.remove("scripts/.tmp_validate_spatial.py")
    }
  })
  cat("\n")
}

# ============================================================
# STEP 5: Clean up temp files
# ============================================================
cat("--- Step 5: Clean up ---\n")
if (file.exists(GEOPARQUET_FILE)) {
  file.remove(GEOPARQUET_FILE)
  cat(sprintf("Removed: %s\n", GEOPARQUET_FILE))
}
if (file.exists("scripts/.tmp_validate_spatial.py")) {
  file.remove("scripts/.tmp_validate_spatial.py")
}
cat("\n")

# ============================================================
# SUMMARY
# ============================================================
cat("=== Spike Summary ===\n\n")

checks <- c(
  "DuckDB CLI execution" = results$duckdb_cli,
  "GEOMETRY type (not BLOB)" = results$geometry_type,
  "Spatial SQL (ST_Area)" = results$spatial_sql,
  "GeoParquet export" = results$geoparquet_export,
  "Pin upload to S3" = results$pin_upload,
  "R sf roundtrip" = results$r_roundtrip,
  "Python geopandas roundtrip" = results$python_roundtrip
)

passed <- sum(unlist(checks))
total <- length(checks)

for (name in names(checks)) {
  status <- if (checks[[name]]) "PASS" else "FAIL"
  cat(sprintf("  [%s] %s\n", status, name))
}

cat(sprintf("\nResult: %d/%d checks passed\n", passed, total))

if (passed == total) {
  cat("\nSpatial pipeline fully validated. Safe to proceed with all 8 tables.\n")
} else {
  cat("\nSome checks failed. Review output above before proceeding.\n")
}

cat("\nDone.\n")
