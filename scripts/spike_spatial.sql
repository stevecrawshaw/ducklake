-- spike_spatial.sql
-- Spike: Validate the full spatial pipeline with bdline_ua_lep_diss_tbl (1 row).
-- Steps: DuckLake GEOMETRY recreation, spatial SQL, GeoParquet export.
--
-- Usage: Executed via DuckDB CLI from spike_spatial.R
--   duckdb -init scripts/spike_spatial.sql -c "SELECT 1;" -no-stdin

-- Extensions
INSTALL ducklake;
LOAD ducklake;
INSTALL httpfs;
LOAD httpfs;
INSTALL aws;
LOAD aws;
INSTALL spatial;
LOAD spatial;

-- S3 credentials
CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);

-- Attach DuckLake catalogue (read-write for table recreation)
ATTACH 'ducklake:data/mca_env.ducklake' AS lake (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

-- Attach source database (read-only)
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);

-- Step 1: Drop existing BLOB-typed table
DROP TABLE IF EXISTS lake.bdline_ua_lep_diss_tbl;

-- Step 2: Recreate with native GEOMETRY via ST_GeomFromWKB
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl;

-- Step 3: Verify GEOMETRY type (should NOT be BLOB)
SELECT 'GEOMETRY_TYPE_CHECK' AS test, typeof(shape) AS result
  FROM lake.bdline_ua_lep_diss_tbl
  LIMIT 1;

-- Step 4: Spatial SQL test -- ST_Area should return non-zero
SELECT 'SPATIAL_SQL_CHECK' AS test, ST_Area(shape) AS area_sqm
  FROM lake.bdline_ua_lep_diss_tbl;

-- Step 5: Export GeoParquet to temp file
COPY (SELECT * FROM lake.bdline_ua_lep_diss_tbl) TO 'data/tmp_spike_spatial.parquet' (FORMAT PARQUET);

-- Step 6: Verify GeoParquet metadata (look for 'geo' key)
SELECT 'GEOPARQUET_META_CHECK' AS test, key, value
  FROM parquet_kv_metadata('data/tmp_spike_spatial.parquet')
  WHERE key = 'geo';
