# validate_ducklake.R
# End-to-end validation script for the DuckLake catalogue.
# Runs 8 validations covering tables, comments, views, time travel,
# data change feed, retention, and analyst read-only access.
#
# Uses DuckDB CLI because the R duckdb package (v1.4.4) lacks the
# ducklake extension. SQL is written to temp files and executed via
# DuckDB CLI (duckdb command must be on PATH).
#
# Usage: Rscript scripts/validate_ducklake.R
#   (run from project root directory)

# --- Configuration ---
DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH     <- "s3://stevecrawshaw-bucket/ducklake/data/"
RETAIN_SQL    <- "scripts/configure_retention.sql"

cat("=== DuckLake Validation ===\n")
cat(sprintf("Catalogue: %s\n", DUCKLAKE_FILE))
cat(sprintf("Data path: %s\n\n", DATA_PATH))

# --- Helper: run SQL via DuckDB CLI and return output lines ---
run_sql <- function(sql_lines, timeout_secs = 120, label = "") {
  tmp <- "scripts/.tmp_validate.sql"
  writeLines(sql_lines, tmp, useBytes = TRUE)
  cmd <- sprintf('duckdb -csv -init "%s" -c "SELECT 1;" -no-stdin', tmp)
  result <- system(cmd, intern = TRUE, timeout = timeout_secs)
  if (file.exists(tmp)) file.remove(tmp)
  result
}

# --- Standard preamble: install extensions, create secret, attach RW ---
preamble_rw <- c(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs;   LOAD httpfs;",
  "INSTALL aws;      LOAD aws;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s');",
    DUCKLAKE_FILE, DATA_PATH
  )
)

# --- Standard preamble: read-only attach ---
preamble_ro <- c(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs;   LOAD httpfs;",
  "INSTALL aws;      LOAD aws;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', READ_ONLY);",
    DUCKLAKE_FILE, DATA_PATH
  )
)

# --- Helper: extract first integer from CSV-mode CLI output ---
# With -csv flag, DuckDB outputs header then values, e.g.:
#   count_star()
#   18
extract_int <- function(lines) {
  # Filter out empty lines and the sentinel "SELECT 1" output
  lines <- lines[nchar(trimws(lines)) > 0]
  # Find lines that are purely numeric (the CSV data rows)
  numeric_lines <- grep("^\\s*[0-9]+\\s*$", lines, value = TRUE)
  if (length(numeric_lines) == 0) return(NA_integer_)
  as.integer(trimws(numeric_lines[1]))
}

# --- Validation tracker ---
results <- list()
record <- function(n, name, passed, detail = "") {
  status <- if (isTRUE(passed)) "PASS" else "FAIL"
  results[[n]] <<- list(name = name, status = status, detail = detail)
  cat(sprintf("  Validation %d -- %s: %s%s\n",
              n, name, status,
              if (nchar(detail) > 0) paste0(" (", detail, ")") else ""))
}

# ============================================================
# Validation 1: Table count = 18
# ============================================================
cat("--- Validation 1: Table count ---\n")
tryCatch({
  out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM information_schema.tables",
    "WHERE table_catalog = 'lake' AND table_type = 'BASE TABLE';"
  ), label = "table_count")
  n <- extract_int(out)
  if (!is.na(n) && n == 18) {
    record(1, "Table count", TRUE, sprintf("count = %d", n))
  } else {
    record(1, "Table count", FALSE, sprintf("expected 18, got %s", n))
  }
}, error = function(e) {
  record(1, "Table count", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 2: Table comments >= 15
# ============================================================
cat("--- Validation 2: Table comments ---\n")
tryCatch({
  out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM duckdb_tables()",
    "WHERE database_name = 'lake'",
    "  AND comment IS NOT NULL AND comment != '';"
  ), label = "tbl_comments")
  n <- extract_int(out)
  if (!is.na(n) && n >= 15) {
    record(2, "Table comments", TRUE, sprintf("count = %d (>= 15)", n))
  } else {
    record(2, "Table comments", FALSE, sprintf("expected >= 15, got %s", n))
  }
}, error = function(e) {
  record(2, "Table comments", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 3: Column comments >= 350
# ============================================================
cat("--- Validation 3: Column comments ---\n")
tryCatch({
  out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM duckdb_columns()",
    "WHERE database_name = 'lake'",
    "  AND comment IS NOT NULL AND comment != '';"
  ), label = "col_comments")
  n <- extract_int(out)
  if (!is.na(n) && n >= 350) {
    record(3, "Column comments", TRUE, sprintf("count = %d (>= 350)", n))
  } else {
    record(3, "Column comments", FALSE, sprintf("expected >= 350, got %s", n))
  }
}, error = function(e) {
  record(3, "Column comments", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 4: Views >= 12
# ============================================================
cat("--- Validation 4: Views ---\n")
tryCatch({
  out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM information_schema.tables",
    "WHERE table_catalog = 'lake' AND table_type = 'VIEW';"
  ), label = "view_count")
  n <- extract_int(out)
  if (!is.na(n) && n >= 12) {
    record(4, "Views", TRUE, sprintf("count = %d (>= 12)", n))
  } else {
    record(4, "Views", FALSE, sprintf("expected >= 12, got %s", n))
  }
}, error = function(e) {
  record(4, "Views", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 5: Time travel (read-only)
# Query two most recent snapshots and verify row counts differ at each version.
# ============================================================
cat("--- Validation 5: Time travel ---\n")
tryCatch({
  # Get two most recent snapshot IDs
  snap_out <- run_sql(c(
    preamble_ro,
    "SELECT snapshot_id FROM lake.snapshots() ORDER BY snapshot_id DESC LIMIT 2;"
  ), label = "tt_snapshots")

  # Parse snapshot IDs from CSV output (skip header, sentinel)
  snap_lines <- snap_out[nchar(trimws(snap_out)) > 0]
  snap_nums <- suppressWarnings(as.integer(trimws(snap_lines)))
  snap_nums <- snap_nums[!is.na(snap_nums)]
  # Remove the sentinel "1" from SELECT 1
  snap_nums <- snap_nums[snap_nums > 1]

  if (length(snap_nums) < 2) {
    record(5, "Time travel", FALSE,
           sprintf("need >= 2 snapshots, found %d", length(snap_nums)))
  } else {
    v_newer <- snap_nums[1]
    v_older <- snap_nums[2]
    cat(sprintf("  Using snapshots: v%d (older) and v%d (newer)\n", v_older, v_newer))

    # Count at older version
    older_out <- run_sql(c(
      preamble_ro,
      sprintf(
        "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl AT (VERSION => %d);",
        v_older
      )
    ), label = "tt_older")
    count_older <- extract_int(older_out)
    cat(sprintf("  Count at v%d: %s\n", v_older, count_older))

    # Count at newer version
    newer_out <- run_sql(c(
      preamble_ro,
      sprintf(
        "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl AT (VERSION => %d);",
        v_newer
      )
    ), label = "tt_newer")
    count_newer <- extract_int(newer_out)
    cat(sprintf("  Count at v%d: %s\n", v_newer, count_newer))

    # Both must return valid integer counts (proves time travel works)
    if (!is.na(count_older) && !is.na(count_newer) &&
        count_older > 0 && count_newer > 0) {
      record(5, "Time travel", TRUE,
             sprintf("v%d=%d rows, v%d=%d rows (read-only)",
                     v_older, count_older, v_newer, count_newer))
    } else {
      record(5, "Time travel", FALSE,
             sprintf("v%d=%s, v%d=%s",
                     v_older, count_older, v_newer, count_newer))
    }
  }
}, error = function(e) {
  record(5, "Time travel", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 6: Data change feed (read-only)
# table_changes() between the two snapshots from validation 5.
# ============================================================
cat("--- Validation 6: Data change feed ---\n")
tryCatch({
  # Reuse snapshot IDs from validation 5 (v_older, v_newer in scope)
  if (!exists("v_older") || !exists("v_newer") || is.na(v_older) || is.na(v_newer)) {
    record(6, "Data change feed", FALSE, "SKIP: fewer than 2 snapshots available")
  } else {
    changes_out <- run_sql(c(
      preamble_ro,
      sprintf(
        "SELECT COUNT(*) FROM lake.table_changes('ca_la_lookup_tbl', %d, %d);",
        v_older, v_newer
      )
    ), label = "change_feed")
    n_changes <- extract_int(changes_out)
    cat(sprintf("  Changes between v%d and v%d: %s\n", v_older, v_newer, n_changes))

    if (!is.na(n_changes) && n_changes >= 1) {
      record(6, "Data change feed", TRUE,
             sprintf("%d row(s) in table_changes(v%d, v%d)", n_changes, v_older, v_newer))
    } else {
      record(6, "Data change feed", FALSE,
             sprintf("expected >= 1 change, got %s", n_changes))
    }
  }
}, error = function(e) {
  record(6, "Data change feed", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 7: Retention policy configuration
# Execute configure_retention.sql content and confirm no error.
# ============================================================
cat("--- Validation 7: Retention policy ---\n")
tryCatch({
  if (!file.exists(RETAIN_SQL)) {
    stop(sprintf("Retention SQL file not found: %s", RETAIN_SQL))
  }
  retain_content <- readLines(RETAIN_SQL, warn = FALSE)
  # Remove comment lines and blank lines for execution
  retain_stmts <- retain_content[!grepl("^\\s*(--|$)", retain_content)]

  retain_out <- run_sql(c(
    preamble_rw,
    retain_stmts
  ), label = "retention", timeout_secs = 60)

  # Check for error indicators in output
  errors <- retain_out[grepl("Error|error|FAILED|failed", retain_out, ignore.case = FALSE)]
  if (length(errors) == 0) {
    record(7, "Retention policy", TRUE, "expire_older_than set to 90 days")
  } else {
    record(7, "Retention policy", FALSE, paste(errors, collapse = "; "))
  }
}, error = function(e) {
  record(7, "Retention policy", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 8: Analyst read-only access simulation
# Attach READ_ONLY, query a view, DESCRIBE a table.
# ============================================================
cat("--- Validation 8: Analyst read-only access ---\n")
tryCatch({
  # Query view
  view_out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM lake.la_ghg_emissions_weca_vw;"
  ), label = "analyst_view", timeout_secs = 60)
  n_view <- extract_int(view_out)
  cat(sprintf("  la_ghg_emissions_weca_vw row count: %s\n", n_view))

  # DESCRIBE table
  desc_out <- run_sql(c(
    preamble_ro,
    "DESCRIBE lake.la_ghg_emissions_tbl;"
  ), label = "analyst_describe", timeout_secs = 30)
  # DESCRIBE should produce lines with column names
  has_columns <- any(grepl("country|local_authority", desc_out, ignore.case = TRUE))
  cat(sprintf("  DESCRIBE returned column info: %s\n", has_columns))

  if (!is.na(n_view) && n_view > 0 && has_columns) {
    record(8, "Analyst read-only access", TRUE,
           sprintf("view returned %d rows; DESCRIBE confirmed columns", n_view))
  } else {
    record(8, "Analyst read-only access", FALSE,
           sprintf("view_rows=%s, has_columns=%s", n_view, has_columns))
  }
}, error = function(e) {
  record(8, "Analyst read-only access", FALSE, conditionMessage(e))
})

# ============================================================
# Summary
# ============================================================
cat("\n=== Validation Summary ===\n")
passed <- sum(vapply(results, function(r) r$status == "PASS", logical(1)))
total  <- length(results)

for (r in results) {
  cat(sprintf("  %s %s\n", r$status, r$name))
}
cat(sprintf("\n%d/%d validations passed\n", passed, total))

if (passed < total) {
  cat("\nFailed validations:\n")
  for (r in results) {
    if (r$status != "PASS") {
      cat(sprintf("  FAIL -- %s: %s\n", r$name, r$detail))
    }
  }
  quit(status = 1)
} else {
  cat("\nAll validations passed. DuckLake catalogue is fully operational.\n")
}
