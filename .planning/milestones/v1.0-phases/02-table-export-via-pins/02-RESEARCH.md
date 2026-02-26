# Phase 2: Table Export via Pins - Research

**Researched:** 2026-02-22
**Domain:** pins (R + Python), DuckDB metadata extraction, S3 parquet export
**Confidence:** MEDIUM (cross-language interop is the key risk)

## Summary

Phase 2 exports non-spatial tables from a local DuckDB database to S3 as parquet files via the pins package, with metadata (table and column descriptions) preserved. Analysts then discover and read these datasets from both R and Python using pins' `board_s3` abstraction.

The standard approach is: (1) connect to the source DuckDB and extract table/column metadata using `duckdb_tables()` and `duckdb_columns()`, (2) identify and exclude tables with WKB_BLOB/geometry columns (deferred to Phase 4), (3) write each table as a pin using R's `pins::pin_write()` with `type = "parquet"` and custom metadata containing descriptions, (4) validate that Python's `pins` package can read the same pins from the same S3 board.

The critical risk is cross-language interoperability. R and Python pins packages share the same on-disc format (data.txt YAML manifest + versioned directories), and parquet is language-independent, so the design should work. However, this has LOW confidence from prior research and must be validated early. The R package uses `paws.storage` for S3 access while Python uses `fsspec`/`s3fs`, so authentication differences could surface.

**Primary recommendation:** Write pins from R (proven working per `aws_setup.r`), validate reading from Python immediately. Use parquet format exclusively. Store table and column descriptions in the pin's `metadata$user` field as a structured list.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| pins (R) | 1.4.0+ (CRAN) | Write pins to S3 board | Already proven in `aws_setup.r`; `board_s3()` + `pin_write()` |
| pins (Python) | 0.9.1 | Read pins from S3 board | Official Posit counterpart; same on-disc format as R |
| DuckDB (R) | 1.4.4+ | Read source database, extract metadata | Source is a DuckDB file |
| DuckDB (Python) | 1.4.4+ | Alternative for metadata extraction | Already in `pyproject.toml` |
| arrow (R) | latest | Parquet read/write support for pins | Required by pins for parquet format |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| s3fs (Python) | latest | S3 filesystem access for Python pins | Installed via `pip install pins[aws]` or `uv add pins[aws]` |
| paws.storage (R) | latest | S3 access for R pins | Pulled in by `pins::board_s3()` |
| boto3 (Python) | 1.42.54+ | AWS SDK (already in pyproject.toml) | Not directly needed for pins (uses s3fs), but useful for debugging |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| pins (R) for writing | DuckDB COPY TO + manual S3 upload | Loses pins metadata/versioning; analysts cannot use `pin_read()` |
| pins (Python) for writing | Write from Python instead of R | Possible, but R path is already proven in this project |
| parquet format | CSV or arrow IPC | CSV loses types; arrow IPC less portable across languages |

**Installation:**
```r
# R
install.packages(c("pins", "arrow", "duckdb", "paws.storage"))
```
```bash
# Python - note the [aws] extra for S3 support
uv add "pins[aws]>=0.9.1"
```

## Architecture Patterns

### Recommended Project Structure
```
scripts/
├── export_pins.r          # Main export script (R) -- writes all non-spatial tables
├── extract_metadata.sql   # SQL queries to extract table/column metadata
└── validate_pins.py       # Python validation script -- reads pins written by R
```

### Pattern 1: Write from R, Read from Both Languages

**What:** Use R to write all pins (since `board_s3` is already working in R), then validate reading from both R and Python.
**When to use:** Always -- this is the primary pattern for Phase 2.
**Example:**
```r
# Source: pins.rstudio.com/reference/board_s3.html
library(pins)
library(duckdb)

# Connect to source DuckDB
con <- dbConnect(duckdb(), "path/to/source.duckdb", read_only = TRUE)

# Create S3 board with prefix
board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  prefix = "pins/",
  region = "eu-west-2",
  versioned = TRUE
)

# Extract table metadata
table_meta <- dbGetQuery(con, "
  SELECT table_name, comment
  FROM duckdb_tables()
  WHERE schema_name = 'main'
    AND internal = false
")

# Extract column metadata for a specific table
col_meta <- dbGetQuery(con, "
  SELECT column_name, data_type, comment
  FROM duckdb_columns()
  WHERE table_name = 'my_table'
    AND schema_name = 'main'
")

# Read table data
df <- dbReadTable(con, "my_table")

# Write as pin with custom metadata
pin_write(
  board,
  x = df,
  name = "my_table",
  type = "parquet",
  title = table_meta$comment,  # table description as title
  description = table_meta$comment,
  metadata = list(
    source = "ducklake",
    columns = setNames(
      as.list(col_meta$comment),
      col_meta$column_name
    )
  )
)
```

### Pattern 2: Python Pin Reading

**What:** Read pins from S3 using Python pins package.
**When to use:** Validation step and analyst workflow.
**Example:**
```python
# Source: rstudio.github.io/pins-python/reference/board_s3.html
from pins import board_s3

# Note: Python board_s3 takes path as "bucket/prefix" (different from R!)
board = board_s3("stevecrawshaw-bucket/pins", versioned=True)

# List all pins
board.pin_list()

# Read a pin (returns pandas DataFrame)
df = board.pin_read("my_table")

# Read metadata
meta = board.pin_meta("my_table")
# Custom metadata is in meta.user
column_descriptions = meta.user.get("columns", {})
```

### Pattern 3: Metadata Extraction from DuckDB

**What:** Extract table and column comments from DuckDB's built-in metadata functions.
**When to use:** Before exporting each table.
**Example:**
```sql
-- All table names with comments (excluding internal tables)
SELECT table_name, comment, column_count, estimated_size
FROM duckdb_tables()
WHERE schema_name = 'main'
  AND internal = false;

-- All column metadata for a specific table
SELECT table_name, column_name, column_index, data_type, comment
FROM duckdb_columns()
WHERE schema_name = 'main'
  AND table_name = 'my_table'
ORDER BY column_index;

-- Identify geometry/spatial tables to EXCLUDE from Phase 2
SELECT DISTINCT table_name
FROM duckdb_columns()
WHERE schema_name = 'main'
  AND (data_type ILIKE '%BLOB%' OR data_type ILIKE '%GEOMETRY%' OR data_type ILIKE '%WKB%');
```

### Anti-Patterns to Avoid
- **Writing pins from Python and reading from R:** While theoretically supported, the R path is proven. Stick with one write language.
- **Using CSV format for pins:** Loses type information, slow for large tables. Always use parquet.
- **Hardcoding table names:** Query `duckdb_tables()` dynamically to get the full list.
- **Storing metadata in separate files:** Use the pins metadata system (`metadata` parameter) rather than sidecar files.
- **Loading entire 19M-row table into R memory at once:** Use DuckDB's streaming or chunked export instead.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| S3 file management | Custom boto3 upload scripts | `pins::board_s3()` / `pins.board_s3()` | Pins handles versioning, manifest, metadata YAML |
| Metadata YAML format | Custom YAML sidecar files | `pin_write(metadata = ...)` | Pins has a standard `data.txt` format with `$user` field |
| Parquet serialisation | Manual `arrow::write_parquet()` to S3 | `pin_write(type = "parquet")` | Pins wraps this and adds manifest/metadata |
| Pin discovery | Custom S3 listing scripts | `pin_list()` / `pin_search()` | Pins reads `_pins.yaml` manifest |
| Version management | Custom timestamped folders | `pins` versioning (default: `versioned = TRUE`) | Pins uses `YYYYMMDDTHHMMSSZ-hash` versioned directories |

**Key insight:** The pins package manages an entire mini data catalogue on S3 -- manifest, versioning, metadata, and data files. Writing raw parquet to S3 would mean rebuilding this infrastructure from scratch and losing the analyst-facing `pin_list()`/`pin_read()` workflow.

## Common Pitfalls

### Pitfall 1: Python board_s3 Path Format Differs from R
**What goes wrong:** R uses `board_s3(bucket = "bucket", prefix = "pins/")` while Python uses `board_s3("bucket/pins")`. Getting this wrong means Python cannot find pins written by R.
**Why it happens:** The two packages have different API signatures.
**How to avoid:** Test Python reading immediately after R writing. The correct Python call is `board_s3("stevecrawshaw-bucket/pins")`.
**Warning signs:** `pin_list()` returns empty list, or "pin does not exist" errors.

### Pitfall 2: Python pins Missing S3 Dependencies
**What goes wrong:** `pins` Python package installed without the `[aws]` extra, so `s3fs`/`fsspec` are missing.
**Why it happens:** `pip install pins` does not include S3 support by default.
**How to avoid:** Install with `uv add "pins[aws]>=0.9.1"` or ensure `s3fs` is in dependencies.
**Warning signs:** ImportError for s3fs or fsspec when creating board_s3.

### Pitfall 3: Large Table OOM During Export
**What goes wrong:** The 19M-row EPC table causes R to run out of memory when loaded entirely into a data frame.
**Why it happens:** R loads entire data frames into RAM. 19M rows with many columns could exceed available memory.
**How to avoid:** Two strategies:
  1. Use DuckDB's `COPY` to write parquet to a temp file, then use `pin_upload()` (file-based) instead of `pin_write()` (object-based).
  2. If memory permits, use `dbReadTable()` but monitor memory usage.
  DuckDB itself handles large exports well with `ROW_GROUP_SIZE` control.
**Warning signs:** R session crashes or hangs during `dbReadTable()` for the EPC table.

### Pitfall 4: AWS Authentication Differences Between R and Python
**What goes wrong:** R pins uses `paws.storage` (reads `~/.aws/credentials`), Python pins uses `s3fs`/`fsspec` (reads `AWS_ACCESS_KEY_ID` env vars or `~/.aws/credentials`).
**Why it happens:** Different S3 client libraries with different credential resolution chains.
**How to avoid:** Ensure `~/.aws/credentials` file is configured (works for both). For Python, can also set `AWS_DEFAULT_REGION=eu-west-2` environment variable.
**Warning signs:** R works but Python gets 403 or "unable to determine region" errors.

### Pitfall 5: Pin Names with Special Characters
**What goes wrong:** Pin names cannot contain slashes or certain special characters.
**Why it happens:** Pin names map to S3 directory paths.
**How to avoid:** Use simple snake_case table names as pin names. DuckDB table names should already be clean.
**Warning signs:** Error on `pin_write()` about invalid pin name.

### Pitfall 6: Missing `_pins.yaml` Manifest
**What goes wrong:** `pin_list()` returns nothing even though pins exist on S3.
**Why it happens:** The `_pins.yaml` manifest at the board root was not created or updated.
**How to avoid:** Always use `pin_write()` (not manual S3 upload). The pins package maintains the manifest automatically.
**Warning signs:** Pins exist in S3 browser but `pin_list()` is empty.

## Code Examples

### Extract All Metadata from Source DuckDB (Python)

```python
# Source: duckdb.org/docs/stable/sql/statements/comment_on
import duckdb

con = duckdb.connect("path/to/source.duckdb", read_only=True)

# Get all tables with metadata
tables = con.execute("""
    SELECT table_name, comment, estimated_size, column_count
    FROM duckdb_tables()
    WHERE schema_name = 'main'
      AND internal = false
    ORDER BY table_name
""").fetchdf()

# Get all columns with metadata
columns = con.execute("""
    SELECT table_name, column_name, column_index, data_type, comment
    FROM duckdb_columns()
    WHERE schema_name = 'main'
    ORDER BY table_name, column_index
""").fetchdf()

# Identify spatial tables to exclude
spatial_tables = con.execute("""
    SELECT DISTINCT table_name
    FROM duckdb_columns()
    WHERE schema_name = 'main'
      AND (data_type ILIKE '%BLOB%'
           OR data_type ILIKE '%GEOMETRY%'
           OR data_type ILIKE '%WKB%')
""").fetchdf()

# Non-spatial tables for Phase 2
non_spatial = tables[~tables['table_name'].isin(spatial_tables['table_name'])]
```

### R: Export All Non-Spatial Tables as Pins

```r
# Source: pins.rstudio.com/reference/board_s3.html, pin_write docs
library(pins)
library(duckdb)

con <- dbConnect(duckdb(), "path/to/source.duckdb", read_only = TRUE)
board <- board_s3(
  bucket = "stevecrawshaw-bucket",
  prefix = "pins/",
  region = "eu-west-2",
  versioned = TRUE
)

# Get table list and metadata
tables <- dbGetQuery(con, "
  SELECT table_name, comment, estimated_size
  FROM duckdb_tables()
  WHERE schema_name = 'main' AND internal = false
")

# Get spatial tables to exclude
spatial <- dbGetQuery(con, "
  SELECT DISTINCT table_name FROM duckdb_columns()
  WHERE schema_name = 'main'
    AND (data_type ILIKE '%BLOB%' OR data_type ILIKE '%GEOMETRY%' OR data_type ILIKE '%WKB%')
")

non_spatial <- tables[!tables$table_name %in% spatial$table_name, ]

for (i in seq_len(nrow(non_spatial))) {
  tbl_name <- non_spatial$table_name[i]
  tbl_comment <- non_spatial$comment[i]

  # Get column metadata
  col_meta <- dbGetQuery(con, sprintf("
    SELECT column_name, data_type, comment
    FROM duckdb_columns()
    WHERE table_name = '%s' AND schema_name = 'main'
    ORDER BY column_index
  ", tbl_name))

  # Read data
  df <- dbReadTable(con, tbl_name)

  # Write pin with metadata
  pin_write(
    board,
    x = df,
    name = tbl_name,
    type = "parquet",
    title = ifelse(is.na(tbl_comment), tbl_name, tbl_comment),
    description = tbl_comment,
    metadata = list(
      source_db = "ducklake",
      columns = setNames(
        as.list(ifelse(is.na(col_meta$comment), "", col_meta$comment)),
        col_meta$column_name
      ),
      column_types = setNames(
        as.list(col_meta$data_type),
        col_meta$column_name
      )
    )
  )
  message(sprintf("Exported: %s (%d rows)", tbl_name, nrow(df)))
}
dbDisconnect(con, shutdown = TRUE)
```

### R: Large Table Export Using pin_upload (File-Based)

```r
# For the 19M-row EPC table if memory is an issue
# Step 1: Use DuckDB COPY to write parquet directly (no R memory needed)
dbExecute(con, sprintf(
  "COPY (SELECT * FROM %s) TO '%s' (FORMAT PARQUET, ROW_GROUP_SIZE 100000)",
  tbl_name,
  temp_parquet_path
))

# Step 2: Upload the parquet file as a pin
pin_upload(
  board,
  paths = temp_parquet_path,
  name = tbl_name,
  title = tbl_comment,
  description = tbl_comment,
  metadata = list(
    source_db = "ducklake",
    columns = col_descriptions_list
  )
)

# Note: pin_upload stores the raw file. pin_read will use arrow to read it.
# The file extension must be .parquet for automatic type detection.
```

### Python: Validate Pin Reading

```python
# Source: rstudio.github.io/pins-python/reference/board_s3.html
import os
from pins import board_s3

# Ensure region is set (Python s3fs needs it)
os.environ.setdefault("AWS_DEFAULT_REGION", "eu-west-2")

# Note: Python path format is "bucket/prefix" (no trailing slash)
board = board_s3("stevecrawshaw-bucket/pins", versioned=True)

# List all available pins
all_pins = board.pin_list()
print(f"Available pins: {all_pins}")

# Read a specific pin
df = board.pin_read("my_table")
print(f"Shape: {df.shape}")
print(f"Columns: {list(df.columns)}")
print(f"Dtypes:\n{df.dtypes}")

# Read metadata including custom fields
meta = board.pin_meta("my_table")
print(f"Title: {meta.title}")
print(f"Description: {meta.description}")
print(f"Custom metadata: {meta.user}")
# Access column descriptions
if "columns" in meta.user:
    for col_name, col_desc in meta.user["columns"].items():
        print(f"  {col_name}: {col_desc}")
```

## S3 Storage Layout

Pins creates this structure on S3 under the `pins/` prefix:

```
s3://stevecrawshaw-bucket/pins/
├── _pins.yaml                           # Board manifest listing all pins
├── imd2025_england_lsoa21/
│   └── 20260222T120000Z-abc12/         # Versioned directory
│       ├── data.txt                     # Pin metadata (YAML)
│       └── imd2025_england_lsoa21.parquet  # Actual data file
├── another_table/
│   └── 20260222T120100Z-def34/
│       ├── data.txt
│       └── another_table.parquet
└── ...
```

**`_pins.yaml`** (board manifest):
```yaml
imd2025_england_lsoa21:
  - imd2025_england_lsoa21/20260222T120000Z-abc12/
another_table:
  - another_table/20260222T120100Z-def34/
```

**`data.txt`** (pin metadata, per-version):
```yaml
file_name: imd2025_england_lsoa21.parquet
type: parquet
title: "IMD 2025 England LSOA21 scores"
description: "Index of Multiple Deprivation 2025 scores at LSOA21 level"
api_version: 1
created: '20260222T120000Z'
pin_hash: abc12def34
user:
  source_db: ducklake
  columns:
    lsoa21cd: "LSOA 2021 code"
    imd_score: "Overall IMD score"
    ...
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| pins v0 (legacy API) | pins v1 (modern API) | 2022 (R), 2022 (Python) | New `board_s3()` + `pin_write()` API; old `pin()` deprecated |
| R-only pins | R + Python pins | 2022 | Python package mirrors R API; same on-disc format |
| CSV pins | Parquet pins | ~2022 | Parquet preserves types, much faster for large datasets |

**Deprecated/outdated:**
- `pins::pin()` (old API): Use `pin_write()` instead
- `pins::board_register_s3()` (old API): Use `board_s3()` instead
- `pins::pin_get()` (old API): Use `pin_read()` instead

## Open Questions

1. **Cross-language metadata fidelity**
   - What we know: R writes metadata to `data.txt` YAML with `$user` field. Python reads `meta.user`.
   - What's unclear: Whether complex nested metadata (column descriptions dict) round-trips perfectly between R YAML writer and Python YAML reader.
   - Recommendation: Validate early in plan 02-01 with a single test table before bulk export.

2. **pin_upload vs pin_write for large tables**
   - What we know: `pin_write()` requires the full data frame in memory. `pin_upload()` takes file paths.
   - What's unclear: Whether `pin_read()` in Python correctly reads a pin created via `pin_upload()` (vs `pin_write()`). The file extension should signal parquet format.
   - Recommendation: Test with the EPC table specifically. If `pin_upload` works, it avoids loading 19M rows into R.

3. **Exact list of spatial vs non-spatial tables**
   - What we know: Can query `duckdb_columns()` for BLOB/GEOMETRY types.
   - What's unclear: Exact column type name for WKB geometry in the source DuckDB (could be `BLOB`, `WKB_BLOB`, or `GEOMETRY`).
   - Recommendation: Run the metadata extraction query against the actual source database in plan 02-01 task 1.

4. **Python s3fs authentication from ~/.aws/credentials**
   - What we know: Python's s3fs reads `~/.aws/credentials` by default. R's paws.storage does the same.
   - What's unclear: Whether s3fs picks up the region from `~/.aws/config` or needs `AWS_DEFAULT_REGION` env var.
   - Recommendation: Set `AWS_DEFAULT_REGION=eu-west-2` explicitly in the validation script as a belt-and-braces measure.

## Sources

### Primary (HIGH confidence)
- [pins R board_s3 reference](https://pins.rstudio.com/reference/board_s3.html) - Full constructor signature, auth chain
- [pins R pin_meta reference](https://pins.rstudio.com/reference/pin_meta.html) - Metadata structure, `$user` field
- [pins Python board_s3 reference](https://rstudio.github.io/pins-python/reference/board_s3.html) - Python constructor, path format
- [pins Python pin_write reference](https://rstudio.github.io/pins-python/reference/pin_write.html) - Full signature, metadata param
- [DuckDB COMMENT ON docs](https://duckdb.org/docs/stable/sql/statements/comment_on) - Metadata extraction via `duckdb_tables()`, `duckdb_columns()`
- [DuckDB metadata functions](https://duckdb.org/docs/stable/sql/meta/duckdb_table_functions) - All fields in `duckdb_tables()` (14 cols) and `duckdb_columns()` (16 cols)
- [pins R custom metadata vignette](https://cran.r-project.org/web/packages/pins/vignettes/customise-pins-metadata.html) - User metadata stored in `$user` field

### Secondary (MEDIUM confidence)
- [pins Python get started](https://rstudio.github.io/pins-python/get_started.html) - General workflow confirmation
- [pins R get started vignette](https://cran.r-project.org/web/packages/pins/vignettes/pins.html) - pin_write/pin_read workflow
- [DuckDB parquet export guide](https://duckdb.org/docs/stable/guides/file_formats/parquet_export) - COPY TO parquet with ROW_GROUP_SIZE
- [Pins and Needles blog](https://blog.djnavarro.net/posts/2023-06-12_pins-and-needles/) - S3 directory structure, `_pins.yaml` manifest, `data.txt` format
- [pins Python PyPI](https://pypi.org/project/pins/) - Version 0.9.1, Python >=3.9, `[aws]` extra

### Tertiary (LOW confidence)
- [GitHub issue #217](https://github.com/rstudio/pins-python/issues/217) - Cross-language S3 reading issue (was permissions, not format)
- Cross-language interop claim from search results (multiple sources state R/Python share format, but no single authoritative test documented)

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - R pins `board_s3` is already working in this project; Python pins is well-documented
- Architecture: HIGH - pins storage layout is well-documented; DuckDB metadata extraction is straightforward
- Cross-language interop: LOW - claimed by Posit docs but no authoritative cross-language test found; GitHub issue #217 suggests it works but was a permissions issue
- Large table export: MEDIUM - DuckDB handles it well; the `pin_upload` file-based approach should work but needs testing
- Pitfalls: MEDIUM - derived from documentation and GitHub issues, not from direct experience

**Research date:** 2026-02-22
**Valid until:** 2026-03-22 (30 days -- pins packages are stable, slow-moving)
