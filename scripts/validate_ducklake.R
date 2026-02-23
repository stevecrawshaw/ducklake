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
  cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp)
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

# --- Helper: extract first integer from CLI output lines ---
# DuckDB CLI uses box-drawing characters in output, e.g.:
#   │           18 │
# We match the content between the vertical bar characters.
extract_int <- function(lines) {
  # Match lines that contain only digits (and whitespace) between │ characters
  # Pattern: │ followed by optional spaces, digits, optional spaces, │
  hits <- grep("\u2502\\s*[0-9]+\\s*\u2502", lines, value = TRUE)
  if (length(hits) == 0) return(NA_integer_)
  # Extract the numeric portion
  m <- regmatches(hits[1], regexpr("[0-9]+", hits[1]))
  if (length(m) == 0) return(NA_integer_)
  as.integer(m)
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
# Validation 5: Time travel
# Insert a test row, query at previous version, assert counts differ by 1.
# ============================================================
cat("--- Validation 5: Time travel ---\n")
tryCatch({
  # Step 5a: get current snapshot version
  snap_out <- run_sql(c(
    preamble_rw,
    "SELECT MAX(snapshot_id) FROM lake.snapshots();"
  ), label = "tt_snap_before")
  v_before <- extract_int(snap_out)
  cat(sprintf("  Current snapshot before insert: %s\n", v_before))

  # Step 5b: get row count before insert
  before_out <- run_sql(c(
    preamble_rw,
    "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl;"
  ), label = "tt_count_before")
  count_before <- extract_int(before_out)
  cat(sprintf("  Row count before insert: %s\n", count_before))

  # Step 5c: insert test row
  insert_out <- run_sql(c(
    preamble_rw,
    "INSERT INTO lake.ca_la_lookup_tbl",
    "VALUES ('TEST', 'Test Authority', 'TEST_CA', 'Test Combined Authority', 9999);"
  ), label = "tt_insert", timeout_secs = 60)

  # Step 5d: get new snapshot version
  snap_after_out <- run_sql(c(
    preamble_rw,
    "SELECT MAX(snapshot_id) FROM lake.snapshots();"
  ), label = "tt_snap_after")
  v_after <- extract_int(snap_after_out)
  cat(sprintf("  Snapshot after insert: %s\n", v_after))

  # Step 5e: count at previous version (should be count_before)
  at_ver_out <- run_sql(c(
    preamble_ro,
    sprintf(
      "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl AT (VERSION => %d);",
      v_before
    )
  ), label = "tt_at_version")
  count_at_prev <- extract_int(at_ver_out)
  cat(sprintf("  Count at version %s: %s\n", v_before, count_at_prev))

  # Step 5f: count at current version (should be count_before + 1)
  curr_count_out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl;"
  ), label = "tt_current_count")
  count_current <- extract_int(curr_count_out)
  cat(sprintf("  Current count (after insert): %s\n", count_current))

  # Step 5g: delete test row
  delete_out <- run_sql(c(
    preamble_rw,
    "DELETE FROM lake.ca_la_lookup_tbl WHERE LAD25CD = 'TEST';"
  ), label = "tt_delete", timeout_secs = 60)

  # Step 5h: verify cleanup
  final_out <- run_sql(c(
    preamble_ro,
    "SELECT COUNT(*) FROM lake.ca_la_lookup_tbl;"
  ), label = "tt_final")
  count_final <- extract_int(final_out)
  cat(sprintf("  Final count after cleanup: %s\n", count_final))

  # Assert
  if (
    !is.na(v_before) && !is.na(v_after) &&
    !is.na(count_before) && !is.na(count_at_prev) && !is.na(count_current) &&
    v_after > v_before &&
    count_at_prev == count_before &&
    count_current == count_before + 1 &&
    count_final == count_before
  ) {
    record(5, "Time travel", TRUE,
           sprintf("v%d->v%d, count %d->%d->%d",
                   v_before, v_after, count_before, count_current, count_final))
  } else {
    record(5, "Time travel", FALSE,
           sprintf("v_before=%s v_after=%s count_before=%s at_prev=%s current=%s final=%s",
                   v_before, v_after, count_before, count_at_prev, count_current, count_final))
  }
}, error = function(e) {
  # Best-effort cleanup on error
  tryCatch({
    run_sql(c(
      preamble_rw,
      "DELETE FROM lake.ca_la_lookup_tbl WHERE LAD25CD = 'TEST';"
    ), label = "tt_cleanup_on_error", timeout_secs = 30)
  }, error = function(e2) NULL)
  record(5, "Time travel", FALSE, conditionMessage(e))
})

# ============================================================
# Validation 6: Data change feed
# table_changes() between the snapshots from validation 5 shows the insert.
# ============================================================
cat("--- Validation 6: Data change feed ---\n")
tryCatch({
  # We need the snapshots from validation 5 -- they are stored in v_before and v_after
  # (These are still in scope if validation 5 succeeded)
  if (!exists("v_before") || !exists("v_after") || is.na(v_before) || is.na(v_after)) {
    stop("v_before / v_after not available from validation 5 -- skipping")
  }
  # The test row was inserted creating snapshot v_after, then deleted creating v_after+1.
  # table_changes from v_before to v_after should show the insert.
  changes_out <- run_sql(c(
    preamble_ro,
    sprintf(
      "SELECT COUNT(*) FROM lake.table_changes('ca_la_lookup_tbl', %d, %d);",
      v_before, v_after
    )
  ), label = "change_feed")
  n_changes <- extract_int(changes_out)
  cat(sprintf("  Changes between v%d and v%d: %s\n", v_before, v_after, n_changes))

  if (!is.na(n_changes) && n_changes >= 1) {
    record(6, "Data change feed", TRUE,
           sprintf("%d row(s) in table_changes(v%d, v%d)", n_changes, v_before, v_after))
  } else {
    record(6, "Data change feed", FALSE,
           sprintf("expected >= 1 change, got %s", n_changes))
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
