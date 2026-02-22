-- verify_s3_access.sql
-- Verifies that DuckDB can connect to S3 using credential_chain (no hardcoded keys).
-- Run this from DuckDB after configuring ~/.aws/credentials with your AWS credentials.
--
-- Usage:
--   duckdb < scripts/verify_s3_access.sql
--   or paste into a DuckDB session interactively.

-- Step 1: Install and load the AWS extension (first run only; subsequent runs are no-ops)
INSTALL aws;
LOAD aws;

-- Step 2: Create an S3 secret using credential_chain.
-- CHAIN config means DuckDB reads credentials from ~/.aws/credentials (the default profile).
-- REGION is set explicitly because DuckDB does not reliably inherit the region from
-- ~/.aws/config -- omitting it causes "Unable to determine region" errors even when
-- the config file has a region set.
CREATE OR REPLACE SECRET ducklake_s3 (
    TYPE s3,
    PROVIDER credential_chain,
    CHAIN config,
    REGION 'eu-west-2'
);

-- Step 3: List all objects at the bucket root.
-- Success: returns a list of files/prefixes currently in the bucket.
-- If the bucket is empty, this returns zero rows -- that is fine.
-- If credentials are wrong you will see an HTTP 403 error here.
SELECT * FROM glob('s3://stevecrawshaw-bucket/*');

-- Step 4: List objects under the pins/ prefix.
-- This will return zero rows until Phase 2 exports data, which is expected.
-- Success means the prefix path is reachable (no 403 / permission error).
SELECT file FROM glob('s3://stevecrawshaw-bucket/pins/*') LIMIT 5;
