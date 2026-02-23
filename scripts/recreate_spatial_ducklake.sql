-- recreate_spatial_ducklake.sql
-- Recreate all 8 spatial tables in DuckLake with native GEOMETRY columns.
-- Drops existing BLOB-typed versions and recreates with ST_GeomFromWKB or ST_Multi.
--
-- Edge cases handled:
--   - ca_boundaries_bgc_tbl: mixed POLYGON/MULTIPOLYGON promoted via ST_Multi
--   - lsoa_2021_lep_tbl: 2 invalid geometries flagged with geom_valid BOOLEAN
--
-- Usage: Executed via DuckDB CLI from export_spatial_pins.R
--   duckdb -init scripts/recreate_spatial_ducklake.sql -c "SELECT 1;" -no-stdin

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

-- ============================================================
-- Standard WKB_BLOB tables (6 tables): ST_GeomFromWKB(shape)
-- ============================================================

-- 1. bdline_ua_lep_diss_tbl (1 row, POLYGON, EPSG:27700)
DROP TABLE IF EXISTS lake.bdline_ua_lep_diss_tbl;
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_diss_tbl;

-- 2. bdline_ua_lep_tbl (4 rows, MULTIPOLYGON, EPSG:27700)
DROP TABLE IF EXISTS lake.bdline_ua_lep_tbl;
CREATE TABLE lake.bdline_ua_lep_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_lep_tbl;

-- 3. bdline_ua_weca_diss_tbl (1 row, POLYGON, EPSG:27700)
DROP TABLE IF EXISTS lake.bdline_ua_weca_diss_tbl;
CREATE TABLE lake.bdline_ua_weca_diss_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ua_weca_diss_tbl;

-- 4. bdline_ward_lep_tbl (130 rows, MULTIPOLYGON, EPSG:27700)
DROP TABLE IF EXISTS lake.bdline_ward_lep_tbl;
CREATE TABLE lake.bdline_ward_lep_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.bdline_ward_lep_tbl;

-- 5. codepoint_open_lep_tbl (31,299 rows, POINT, EPSG:27700)
DROP TABLE IF EXISTS lake.codepoint_open_lep_tbl;
CREATE TABLE lake.codepoint_open_lep_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.codepoint_open_lep_tbl;

-- 6. open_uprn_lep_tbl (687,143 rows, POINT, EPSG:27700)
DROP TABLE IF EXISTS lake.open_uprn_lep_tbl;
CREATE TABLE lake.open_uprn_lep_tbl AS
  SELECT * EXCLUDE(shape), ST_GeomFromWKB(shape) AS shape
  FROM source.open_uprn_lep_tbl;

-- ============================================================
-- Mixed geometry type table: ST_Multi(geom) to promote all to MULTIPOLYGON
-- ============================================================

-- 7. ca_boundaries_bgc_tbl (15 rows, mixed POLYGON/MULTIPOLYGON, EPSG:4326)
-- Note: geom column (not shape), source type is already GEOMETRY (not WKB_BLOB)
DROP TABLE IF EXISTS lake.ca_boundaries_bgc_tbl;
CREATE TABLE lake.ca_boundaries_bgc_tbl AS
  SELECT * EXCLUDE(geom), ST_Multi(geom) AS geom
  FROM source.ca_boundaries_bgc_tbl;

-- ============================================================
-- Table with invalid geometries: add geom_valid BOOLEAN flag
-- ============================================================

-- 8. lsoa_2021_lep_tbl (698 rows, MULTIPOLYGON, EPSG:27700, 2 invalid)
DROP TABLE IF EXISTS lake.lsoa_2021_lep_tbl;
CREATE TABLE lake.lsoa_2021_lep_tbl AS
  SELECT * EXCLUDE(shape),
    ST_GeomFromWKB(shape) AS shape,
    ST_IsValid(ST_GeomFromWKB(shape)) AS geom_valid
  FROM source.lsoa_2021_lep_tbl;

-- ============================================================
-- Verification queries
-- ============================================================

-- Check 1: All spatial columns should be GEOMETRY type
SELECT table_name, column_name, data_type
  FROM information_schema.columns
  WHERE table_catalog = 'lake'
    AND column_name IN ('shape', 'geom', 'geom_valid')
  ORDER BY table_name, column_name;

-- Check 2: lsoa_2021_lep_tbl should have exactly 2 invalid geometries
SELECT 'INVALID_GEOM_COUNT' AS test,
  COUNT(*) AS invalid_count
  FROM lake.lsoa_2021_lep_tbl
  WHERE geom_valid = false;

-- Check 3: ca_boundaries_bgc_tbl should have only MULTIPOLYGON
SELECT 'CA_GEOM_TYPE_CHECK' AS test,
  ST_GeometryType(geom) AS geom_type,
  COUNT(*) AS cnt
  FROM lake.ca_boundaries_bgc_tbl
  GROUP BY ST_GeometryType(geom);

-- Check 4: open_uprn_lep_tbl row count (largest table integrity)
SELECT 'UPRN_ROW_COUNT' AS test,
  COUNT(*) AS total_rows
  FROM lake.open_uprn_lep_tbl;
