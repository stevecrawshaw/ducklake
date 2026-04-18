# scripts/migrate_ducklake.R
# One-time migration of data/mca_env.ducklake from DuckLake 0.x schema to 1.0.
# Requires DuckDB CLI >= 1.5.2 and write access to data/mca_env.ducklake.
# Run once after upgrading DuckDB CLI; never needed again.
#
# Usage: Rscript scripts/migrate_ducklake.R  (from project root)

DUCKLAKE_FILE <- "data/mca_env.ducklake"
DATA_PATH     <- "s3://stevecrawshaw-bucket/ducklake/data/"

cat("=== DuckLake 0.x -> 1.0 Schema Migration ===\n")
cat(sprintf("Catalogue: %s\n\n", DUCKLAKE_FILE))

if (!file.exists(DUCKLAKE_FILE)) stop("Catalogue file not found: ", DUCKLAKE_FILE)

backup_file <- paste0(DUCKLAKE_FILE, ".premigration.bak")
file.copy(DUCKLAKE_FILE, backup_file, overwrite = FALSE)
cat(sprintf("Backup written to: %s\n\n", backup_file))

sql <- paste(
  "INSTALL ducklake; LOAD ducklake;",
  "INSTALL httpfs;   LOAD httpfs;",
  "INSTALL aws;      LOAD aws;",
  "INSTALL spatial;  LOAD spatial;",
  "CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);",
  sprintf(
    "ATTACH 'ducklake:%s' AS lake (DATA_PATH '%s', AUTOMATIC_MIGRATION);",
    gsub("\\\\", "/", DUCKLAKE_FILE), DATA_PATH
  ),
  "SELECT 'Migration complete' AS status;",
  sep = "\n"
)

tmp_sql <- "scripts/.tmp_migrate.sql"
writeLines(sql, tmp_sql, useBytes = TRUE)
cmd <- sprintf('duckdb -init "%s" -c "SELECT 1;" -no-stdin', tmp_sql)
cat("Running migration...\n")
result <- system(cmd, intern = TRUE, timeout = 120)
file.remove(tmp_sql)

exit_code <- attr(result, "status")
if (!is.null(exit_code) && exit_code != 0) {
  cat("Migration FAILED. Restoring from backup...\n")
  file.copy(backup_file, DUCKLAKE_FILE, overwrite = TRUE)
  stop("Migration failed. Catalogue restored. Check DuckDB CLI version (need >= 1.5.2).")
}

for (line in result) cat(sprintf("  %s\n", line))
cat(sprintf("\nDone. Backup retained at: %s\n", backup_file))
cat("Delete the backup once you have verified the catalogue works.\n")
