-- create_views.sql
-- Creates 4 non-spatial source views and 8 WECA-filtered views in DuckLake.
-- Spatial-dependent views (ca_boundaries_inc_ns_vw, epc_domestic_lep_vw,
-- epc_non_domestic_lep_vw) are deferred to Phase 4.
--
-- Execute via DuckDB CLI after attaching the DuckLake catalogue as 'lake'.

-- ============================================================
-- 4 Non-spatial source views
-- ============================================================

-- 1. CA/LA lookup including North Somerset (not a combined authority member
--    but part of the WECA LEP area)
CREATE VIEW lake.ca_la_lookup_inc_ns_vw AS
(SELECT LAD25CD AS ladcd, LAD25NM AS ladnm, CAUTH25CD AS cauthcd, CAUTH25NM AS cauthnm
 FROM lake.ca_la_lookup_tbl)
UNION BY NAME
(SELECT 'E06000024' AS ladcd, 'North Somerset' AS ladnm,
        'E47000009' AS cauthcd, 'West of England' AS cauthnm);

-- 2. WECA LEP local authorities (filtered from the inclusive lookup)
CREATE VIEW lake.weca_lep_la_vw AS
SELECT * FROM lake.ca_la_lookup_inc_ns_vw WHERE cauthnm = 'West of England';

-- 3. GHG emissions joined with CA/LA lookup, excluding redundant columns
CREATE VIEW lake.ca_la_ghg_emissions_sub_sector_ods_vw AS
WITH joined_data AS (
    SELECT * FROM lake.la_ghg_emissions_tbl AS ghg
    INNER JOIN lake.ca_la_lookup_inc_ns_vw AS ca ON ghg.local_authority_code = ca.ladcd
)
SELECT * EXCLUDE (country, country_code, ladcd, ladnm, region, second_tier_authority)
FROM joined_data;

-- 4. Domestic EPC view with derived construction year, epoch, tenure, and
--    lodgement date parts
CREATE VIEW lake.epc_domestic_vw AS
SELECT c.*,
    CASE
        WHEN regexp_matches(CONSTRUCTION_AGE_BAND, '(\d{4})-(\d{4})') THEN
            CAST(round((CAST(regexp_extract(CONSTRUCTION_AGE_BAND, '(\d{4})-(\d{4})', 1) AS INTEGER) +
                        CAST(regexp_extract(CONSTRUCTION_AGE_BAND, '(\d{4})-(\d{4})', 2) AS INTEGER)) / 2.0) AS INTEGER)
        WHEN regexp_matches(CONSTRUCTION_AGE_BAND, 'before (\d{4})') THEN
            CAST(regexp_extract(CONSTRUCTION_AGE_BAND, 'before (\d{4})', 1) AS INTEGER) - 1
        WHEN regexp_matches(CONSTRUCTION_AGE_BAND, '(\d{4}) onwards') THEN
            CAST(regexp_extract(CONSTRUCTION_AGE_BAND, '(\d{4}) onwards', 1) AS INTEGER)
        WHEN regexp_matches(CONSTRUCTION_AGE_BAND, '(\d{4})') THEN
            CAST(regexp_extract(CONSTRUCTION_AGE_BAND, '(\d{4})', 1) AS INTEGER)
        ELSE NULL
    END AS NOMINAL_CONSTRUCTION_YEAR,
    CASE
        WHEN NOMINAL_CONSTRUCTION_YEAR < 1900 THEN 'Before 1900'
        WHEN NOMINAL_CONSTRUCTION_YEAR >= 1900 AND NOMINAL_CONSTRUCTION_YEAR <= 1930 THEN '1900 - 1930'
        WHEN NOMINAL_CONSTRUCTION_YEAR > 1930 THEN '1930 to present'
        ELSE 'Unknown'
    END AS CONSTRUCTION_EPOCH,
    CASE
        WHEN lower(TENURE) = 'owner-occupied' THEN 'Owner occupied'
        WHEN lower(TENURE) = 'rented (social)' THEN 'Social rented'
        WHEN lower(TENURE) = 'rental (social)' THEN 'Social rented'
        WHEN lower(TENURE) = 'rental (private)' THEN 'Private rented'
        WHEN lower(TENURE) = 'rented (private)' THEN 'Private rented'
        ELSE NULL
    END AS TENURE_CLEAN,
    year(LODGEMENT_DATETIME) AS LODGEMENT_YEAR,
    month(LODGEMENT_DATETIME) AS LODGEMENT_MONTH,
    day(LODGEMENT_DATETIME) AS LODGEMENT_DAY
FROM lake.raw_domestic_epc_certificates_tbl AS c;

-- ============================================================
-- 8 WECA-filtered views
-- WECA LA codes: E06000022 (Bath & NE Somerset), E06000023 (Bristol),
--                E06000024 (North Somerset), E06000025 (South Gloucestershire)
-- ============================================================

LOAD SPATIAL;

CREATE VIEW lake.epc_domestic_ods_lep_vw AS
SELECT
epc.LMK_KEY,
epc.UPRN,
epc.BUILDING_REFERENCE_NUMBER,
epc.LOCAL_AUTHORITY,
epc.LOCAL_AUTHORITY_LABEL,
epc.PROPERTY_TYPE,
epc.TRANSACTION_TYPE,
epc.CONSTRUCTION_AGE_BAND,
epc.TENURE,
epc.WALLS_DESCRIPTION,
epc.ROOF_DESCRIPTION,
epc.WALLS_ENERGY_EFF,
epc.ROOF_ENERGY_EFF,
epc.MAINHEAT_DESCRIPTION,
epc.MAINHEAT_ENERGY_EFF,
epc.MAIN_FUEL,
epc.SOLAR_WATER_HEATING_FLAG,
epc.CURRENT_ENERGY_RATING,
epc.POTENTIAL_ENERGY_RATING,
epc.CURRENT_ENERGY_EFFICIENCY,
epc.POTENTIAL_ENERGY_EFFICIENCY,
epc.ENERGY_CONSUMPTION_CURRENT,
epc.ENERGY_CONSUMPTION_POTENTIAL,
epc.ENERGY_TARIFF,
epc.CO2_EMISSIONS_CURRENT,
epc.CO2_EMISSIONS_POTENTIAL,
epc.CO2_EMISS_CURR_PER_FLOOR_AREA,
epc.ENVIRONMENT_IMPACT_CURRENT,
epc.ENVIRONMENT_IMPACT_POTENTIAL,
epc.NUMBER_HABITABLE_ROOMS,
epc.NUMBER_HEATED_ROOMS,
epc.PHOTO_SUPPLY,
epc.TOTAL_FLOOR_AREA,
epc.BUILT_FORM,
epc.LODGEMENT_DATETIME,
'{' || uprn.shape.ST_Transform('EPSG:27700', 'EPSG:4326').ST_X() || ', ' ||
       uprn.shape.ST_Transform('EPSG:27700', 'EPSG:4326').ST_Y() || '}' AS geo_point_2d
FROM lake.epc_domestic_vw epc
JOIN lake.open_uprn_lep_tbl uprn
ON epc.UPRN = uprn.UPRN
WHERE epc.LOCAL_AUTHORITY IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.la_ghg_emissions_weca_vw AS
SELECT * FROM lake.la_ghg_emissions_tbl
WHERE local_authority_code IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.la_ghg_emissions_wide_weca_vw AS
SELECT * FROM lake.la_ghg_emissions_wide_tbl
WHERE local_authority_code IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.raw_domestic_epc_weca_vw AS
SELECT * FROM lake.raw_domestic_epc_certificates_tbl
WHERE LOCAL_AUTHORITY IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.raw_non_domestic_epc_weca_vw AS
SELECT * FROM lake.raw_non_domestic_epc_certificates_tbl
WHERE LOCAL_AUTHORITY IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.boundary_lookup_weca_vw AS
SELECT * FROM lake.boundary_lookup_tbl
WHERE ladcd IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.postcode_centroids_weca_vw AS
SELECT * FROM lake.postcode_centroids_tbl
WHERE lad25cd IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.iod2025_weca_vw AS
SELECT * FROM lake.iod2025_tbl
WHERE la_cd IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');

CREATE VIEW lake.ca_la_lookup_weca_vw AS
SELECT * FROM lake.ca_la_lookup_tbl
WHERE LAD25CD IN ('E06000022', 'E06000023', 'E06000024', 'E06000025');
