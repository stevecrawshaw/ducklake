-- create_ducklake.sql
-- Creates a DuckLake catalogue (local file) with data stored on S3.
-- Registers all 18 tables from the source DuckDB database individually.
-- Views are NOT copied (created manually in plan 03-02).
--
-- The catalogue file is local (data/mca_env.ducklake) because DuckDB
-- cannot create a new database file directly on S3. The data files
-- (parquet) are stored on S3 under ducklake/data/.
--
-- Spatial columns (WKB_BLOB, GEOMETRY) are cast to BLOB because DuckLake
-- does not support these user-defined types. Phase 4 will handle proper
-- geometry conversion.
--
-- Usage: Execute via scripts/create_ducklake.R or DuckDB CLI
--
-- Prerequisites:
--   - AWS credentials configured (credential_chain)
--   - Source database at data/mca_env_base.duckdb
--   - S3 bucket stevecrawshaw-bucket accessible in eu-west-2

-- Step 1: Install and load extensions
INSTALL ducklake;
LOAD ducklake;
INSTALL httpfs;
LOAD httpfs;
INSTALL aws;
LOAD aws;
INSTALL spatial;
LOAD spatial;

-- Step 2: Configure S3 credentials via credential chain (no hardcoded keys)
CREATE SECRET s3_cred (
    TYPE s3,
    REGION 'eu-west-2',
    PROVIDER credential_chain
);

-- Step 3: Create a placeholder object so DATA_PATH exists on S3
-- DuckLake requires the data directory to already exist (pitfall 3)
COPY (SELECT 1 AS placeholder) TO 's3://stevecrawshaw-bucket/ducklake/data/.placeholder' (FORMAT CSV);

-- Step 4: Create the DuckLake catalogue (local file, S3 data path)
-- NOTE: S3-hosted .ducklake file does not work (DuckDB cannot create new
-- database files on S3). The catalogue metadata file must be local.
ATTACH 'ducklake:data/mca_env.ducklake'
    AS lake (DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

-- Step 5: Attach the source database (read-only)
ATTACH 'data/mca_env_base.duckdb' AS source (READ_ONLY);

-- Step 6: Register non-spatial tables (10 tables)
-- These copy directly without type issues.
CREATE TABLE lake.boundary_lookup_tbl AS SELECT * FROM source.boundary_lookup_tbl;
CREATE TABLE lake.ca_la_lookup_tbl AS SELECT * FROM source.ca_la_lookup_tbl;
CREATE TABLE lake.eng_lsoa_imd_tbl AS SELECT * FROM source.eng_lsoa_imd_tbl;
CREATE TABLE lake.iod2025_tbl AS SELECT * FROM source.iod2025_tbl;
CREATE TABLE lake.la_ghg_emissions_tbl AS SELECT * FROM source.la_ghg_emissions_tbl;
CREATE TABLE lake.la_ghg_emissions_wide_tbl AS SELECT * FROM source.la_ghg_emissions_wide_tbl;
CREATE TABLE lake.postcode_centroids_tbl AS SELECT * FROM source.postcode_centroids_tbl;
CREATE TABLE lake.raw_domestic_epc_certificates_tbl AS SELECT * FROM source.raw_domestic_epc_certificates_tbl;
CREATE TABLE lake.raw_non_domestic_epc_certificates_tbl AS SELECT * FROM source.raw_non_domestic_epc_certificates_tbl;
CREATE TABLE lake.uk_lsoa_tenure_tbl AS SELECT * FROM source.uk_lsoa_tenure_tbl;

-- Step 7: Register spatial tables (8 tables)
-- DuckLake does not support WKB_BLOB or GEOMETRY types directly.
-- Spatial columns are cast to BLOB to preserve the binary geometry data.
-- Phase 4 will handle proper geometry type conversion.
CREATE TABLE lake.bdline_ua_lep_diss_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.bdline_ua_lep_diss_tbl;
CREATE TABLE lake.bdline_ua_lep_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.bdline_ua_lep_tbl;
CREATE TABLE lake.bdline_ua_weca_diss_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.bdline_ua_weca_diss_tbl;
CREATE TABLE lake.bdline_ward_lep_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.bdline_ward_lep_tbl;
CREATE TABLE lake.ca_boundaries_bgc_tbl AS SELECT * EXCLUDE(geom), geom::BLOB AS geom FROM source.ca_boundaries_bgc_tbl;
CREATE TABLE lake.codepoint_open_lep_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.codepoint_open_lep_tbl;
CREATE TABLE lake.lsoa_2021_lep_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.lsoa_2021_lep_tbl;
CREATE TABLE lake.open_uprn_lep_tbl AS SELECT * EXCLUDE(shape), shape::BLOB AS shape FROM source.open_uprn_lep_tbl;
