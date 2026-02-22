# validate_pins_r.R
# Validates all exported pins are readable from R with correct metadata.
# Acceptance test for Phase 2: all non-spatial tables must be discoverable,
# readable, and have accessible metadata (title, column descriptions).
#
# Usage: Rscript scripts/validate_pins_r.R

library(pins)
library(arrow)

# --- Configuration ---
S3_BUCKET <- "stevecrawshaw-bucket"
S3_PREFIX <- "pins/"
AWS_REGION <- "eu-west-2"
LARGE_ROW_THRESHOLD <- 5000000 # use arrow for tables above this

# --- Create S3 board ---
cat("=== DuckLake Pin Validation (R) ===\n")
cat(sprintf("Board: s3://%s/%s\n\n", S3_BUCKET, S3_PREFIX))

board <- board_s3(
  bucket = S3_BUCKET,
  prefix = S3_PREFIX,
  region = AWS_REGION,
  versioned = TRUE
)

# --- List all pins ---
all_pins <- pin_list(board)
cat(sprintf("Pins found: %d\n\n", length(all_pins)))

if (length(all_pins) == 0) {
  cat("FAIL: No pins found on board.\n")
  quit(status = 1)
}

# --- Validate each pin ---
passed <- 0
failed <- 0
failures <- character(0)

for (pin_name in all_pins) {
  result <- tryCatch({
    # Read metadata first (lightweight)
    meta <- pin_meta(board, pin_name)

    # Check title
    title <- meta$title
    if (is.null(title) || is.na(title) || nchar(trimws(title)) == 0) {
      stop("title is NULL/NA/empty")
    }

    # Check custom column metadata
    col_meta <- meta$user$columns
    if (is.null(col_meta) || !is.list(col_meta) || length(col_meta) == 0) {
      stop("meta$user$columns is missing or empty")
    }

    # Determine read strategy based on pin file count/size
    # For large multi-file pins, use arrow to avoid loading into memory
    pin_paths <- pin_download(board, pin_name)
    n_files <- length(pin_paths)

    # Use arrow for multi-file pins (chunked exports) or if we suspect large data
    if (n_files > 1) {
      # Multi-file pin: read as arrow dataset
      ds <- open_dataset(pin_paths)
      n_row <- ds$num_rows
      n_col <- length(ds$schema)

      if (n_row == 0) stop("arrow dataset has 0 rows")
      if (n_col == 0) stop("arrow dataset has 0 columns")

      # Spot-check: read first 5 rows to verify types
      head_df <- as.data.frame(head(ds, 5))
      if (nrow(head_df) == 0) stop("could not read head of dataset")

    } else {
      # Single-file pin: read with arrow first to check size
      arrow_tbl <- read_parquet(pin_paths[1], as_data_frame = FALSE)
      n_row <- arrow_tbl$num_rows
      n_col <- length(arrow_tbl$schema)

      if (n_row == 0) stop("parquet has 0 rows")
      if (n_col == 0) stop("parquet has 0 columns")

      if (n_row > LARGE_ROW_THRESHOLD) {
        # Large single file: just check head
        head_df <- as.data.frame(head(arrow_tbl, 5))
        if (nrow(head_df) == 0) stop("could not read head of large table")
      } else {
        # Standard table: full pin_read to verify round-trip
        df <- pin_read(board, pin_name)
        n_row <- nrow(df)
        n_col <- ncol(df)
        if (n_row == 0) stop("pin_read returned 0 rows")
        if (n_col == 0) stop("pin_read returned 0 columns")
        rm(df)
      }
    }

    cat(sprintf("PASS: %s (%s rows x %d cols, title: %s)\n",
                pin_name,
                format(n_row, big.mark = ","),
                n_col,
                title))
    "PASS"
  }, error = function(e) {
    msg <- conditionMessage(e)
    cat(sprintf("FAIL: %s -- %s\n", pin_name, msg))
    msg
  })

  if (identical(result, "PASS")) {
    passed <- passed + 1
  } else {
    failed <- failed + 1
    failures <- c(failures, sprintf("%s: %s", pin_name, result))
  }
}

# --- Summary ---
total <- passed + failed
cat(sprintf("\n=== Summary ===\n"))
cat(sprintf("%d/%d pins passed validation\n", passed, total))

if (failed > 0) {
  cat("\nFailed pins:\n")
  for (f in failures) {
    cat(sprintf("  - %s\n", f))
  }
  quit(status = 1)
} else {
  cat("\nAll pins validated successfully.\n")
  quit(status = 0)
}
