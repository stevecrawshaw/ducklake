# Phase 5: Refresh Pipeline and Data Catalogue - Context

**Gathered:** 2026-02-24
**Status:** Ready for planning

<domain>
## Phase Boundary

The data owner can re-export all updated data from the source DuckDB to both pins (S3) and DuckLake with a single command. Analysts can discover what datasets exist — including column details, row counts, and example values — without asking anyone. New export formats, additional data sources, or analyst-facing tools are out of scope.

</domain>

<decisions>
## Implementation Decisions

### Refresh scope & invocation
- Always full refresh — all 18 tables re-exported every run (no selective/incremental)
- Single R script entry point (e.g. `scripts/refresh.R`), consistent with existing `create_ducklake.R` pattern
- Unified single pass handling both non-spatial (parquet) and spatial (GeoParquet) tables — script detects spatial columns and routes accordingly
- Data only — do not re-apply column comments or recreate views (those are structural and rarely change)

### Snapshot & versioning behaviour
- Drop and recreate DuckLake tables on each refresh — DuckLake's 90-day retention policy preserves previous snapshots for time travel
- Pins: new version each time via `pin_write()` — analysts get latest by default, can access history via `pin_versions()`
- Row count validation after each table export — compare source vs destination counts
- Console summary table at end of run showing table name, row count, time taken, pass/fail

### Catalogue format & location
- DuckLake views (queryable via SQL) plus exported as pinned parquet files on S3 — analysts can access either way
- Two normalised tables: `datasets_catalogue` (one row per table/view) and `columns_catalogue` (one row per column)
- Catalogue regenerated automatically at the end of every refresh run — no separate step
- Include both base tables (18) and WECA-filtered views (12) — a `type` column distinguishes tables from views

### Catalogue content & metadata
- Datasets catalogue: name, description, type (table/view), row count, last updated date, source table name (from mca_env_base.duckdb)
- Spatial tables additionally include: geometry type, CRS, bounding box
- Columns catalogue: table name, column name, data type, description, up to 3 distinct non-null example values (sampled from base tables)

### Claude's Discretion
- Internal structure of the refresh R script (function decomposition, error handling patterns)
- How to detect spatial vs non-spatial tables programmatically
- SQL implementation of catalogue views
- How to sample example values efficiently (LIMIT, USING SAMPLE, etc.)
- Console summary table formatting

</decisions>

<specifics>
## Specific Ideas

- Entry point should feel like existing scripts — `Rscript scripts/refresh.R` from project root
- Row count validation pattern: query source table count, query destination, compare, report mismatch
- Catalogue should be immediately useful to someone who's never seen the data — descriptions + example values + types give enough context to start querying

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 05-refresh-pipeline-and-data-catalogue*
*Context gathered: 2026-02-24*
