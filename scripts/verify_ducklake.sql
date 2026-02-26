duckdb
INSTALL ducklake; LOAD ducklake;
CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);
ATTACH 'ducklake:data/mca_env.ducklake' AS lake (READ_ONLY, DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');        
USE lake;
SHOW TABLES;
--   2. Check a table comment:
SELECT comment FROM duckdb_tables() WHERE database_name='lake' AND table_name='la_ghg_emissions_tbl';
--   3. Query a WECA view:
SELECT DISTINCT local_authority_code FROM la_ghg_emissions_weca_vw;
--   4. Check snapshots:
SELECT * FROM lake.snapshots() ORDER BY snapshot_id DESC LIMIT 5;
--- 5. Check comments on columns
SELECT column_name, comment
FROM duckdb_columns()
WHERE database_name='lake' AND table_name='raw_non_domestic_epc_certificates_tbl';