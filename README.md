# WECA Data Platform (DuckLake)

A shared data lake providing **18 curated datasets** for analysts at the West of England Combined Authority. Data is stored on Amazon S3 and accessible through two complementary routes:

- **Pins (R / Python):** Read datasets directly into data frames for exploratory analysis
- **DuckLake (SQL via DuckDB):** Query with SQL, join across tables, use pre-built WECA-filtered views, and browse the data catalogue

Both routes read from the same underlying data.

## What's included

- 18 base tables covering local authority lookups, greenhouse gas emissions, energy performance certificates, deprivation indices, postcode centroids, tenure, and spatial boundaries
- 12 pre-built views filtering to the four WECA local authorities
- 8 spatial datasets as GeoParquet (boundaries, postcodes, UPRN addresses)
- A self-describing data catalogue (`datasets_catalogue` and `columns_catalogue`) with 403 documented columns
- Time travel via DuckLake snapshots

## Repository structure

```
ducklake/
  data/
    mca_env.ducklake      # DuckLake catalogue metadata (local file, a few KB)
    mca_env_base.duckdb   # Source DuckDB database
  scripts/
    refresh.R             # Unified refresh pipeline
    create_ducklake.R     # DuckLake creation
    export_pins.R         # Pin export to S3
    export_spatial_pins.R # Spatial pin export
    create_views.sql      # WECA-filtered views
    apply_comments.R      # Column-level metadata
    ...
  docs/
    analyst-guide.qmd     # Full analyst guide (Quarto)
  aws_setup.r             # AWS credential helper
  main.py                 # Python entry point
```

## Getting started

See the **[Analyst Guide](https://stevecrawshaw.github.io/ducklake/)** for full setup instructions, including:

1. Installing R packages (`pins`, `arrow`, `sf`, `duckdb`)
2. Configuring AWS credentials (`~/.aws/credentials`)
3. Reading data via pins or querying the DuckLake catalogue with SQL

## Quick example (R)

```r
library(pins)

board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  prefix = "pins/",
  region = "eu-west-2",
  versioned = TRUE
)

# List all datasets
pin_list(board)

# Read a dataset
df <- pin_read(board, "ca_la_lookup_tbl")
```

## Quick example (DuckDB CLI)

```sql
INSTALL ducklake; LOAD ducklake;
INSTALL aws; LOAD aws;
CREATE SECRET (TYPE s3, REGION 'eu-west-2', PROVIDER credential_chain);

ATTACH 'ducklake:data/mca_env.ducklake' AS lake
  (READ_ONLY, DATA_PATH 's3://stevecrawshaw-bucket/ducklake/data/');

SELECT * FROM lake.datasets_catalogue ORDER BY type, name;
```

## Requirements

- **R packages:** pins, arrow, sf, duckdb, DBI
- **DuckDB CLI:** Required for DuckLake SQL queries (the R duckdb package lacks the ducklake extension)
- **AWS credentials:** Access key for `stevecrawshaw-bucket` in `eu-west-2`
