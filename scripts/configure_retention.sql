-- configure_retention.sql
-- Sets the DuckLake snapshot retention policy.
-- DuckLake retention is database-wide (not per-table). Snapshots older than
-- the threshold will be expired and their parquet data files deleted from S3.
--
-- Note: The user requested "last 5 versions per table" but DuckLake snapshots
-- are database-level. Time-based retention (90 days) is the closest equivalent.
--
-- Usage: Execute via DuckDB CLI with ducklake extension loaded and catalogue attached.
-- See scripts/validate_ducklake.R for the full preamble.

CALL lake.set_option('expire_older_than', '90 days');
