# Feature Research

**Domain:** Internal data sharing platform for analyst team (DuckDB-to-S3 with DuckLake)
**Researched:** 2026-02-22
**Confidence:** MEDIUM-HIGH (DuckLake docs verified directly; analyst workflow patterns based on project context and domain knowledge)

## Feature Landscape

### Table Stakes (Users Expect These)

Features analysts assume exist. Missing these = platform is not usable.

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **S3 parquet export** | Core purpose: get data from local DuckDB to shared storage analysts can reach | MEDIUM | Must handle 18 tables including 19M+ row EPC table; needs chunking strategy for large tables |
| **Metadata preservation** | Analysts need to know what columns mean without asking the data owner | MEDIUM | DuckDB `COMMENT ON` maps directly to DuckLake `COMMENT ON` (verified in docs). Must also work for pins pathway. Parquet metadata fields can carry comments but pins may not surface them natively |
| **R access (pins)** | Half the team uses R; `board_s3()` + `pin_read()` is their expected workflow | LOW | Already demonstrated in `aws_setup.r`. `pins` supports parquet on S3 boards |
| **Python access (pins)** | Other half uses Python; `pins` Python package supports S3 boards | LOW | Already in `pyproject.toml` dependencies. Same board abstraction as R |
| **DuckLake catalogue access** | The stretch goal and primary differentiator over raw S3 files | MEDIUM | `ATTACH 'ducklake:...'` gives analysts full SQL access to all tables with metadata. Requires DuckDB extension install on analyst machines |
| **Table/column discovery** | Analysts must be able to answer "what data is available and what do columns mean?" without external documentation | LOW | DuckLake stores comments in metadata; `COMMENT ON TABLE/COLUMN` syntax verified. For pins: need a manifest or README approach |
| **AWS credential setup for readers** | Analysts need to authenticate to S3 without complex config | LOW-MEDIUM | DuckLake supports secrets (`CREATE SECRET`); pins uses `.aws` config. Must document both paths |
| **Read-only access for analysts** | Data integrity: analysts consume, they don't modify the shared data | LOW | DuckLake access control guide covers Reader role (SELECT-only on catalogue + S3 read-only IAM policy). Pins boards are read-only by default when no write credentials given |

### Differentiators (Competitive Advantage)

Features that make this significantly better than shared network drives or emailed spreadsheets.

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **DuckLake time travel** | Analysts can query data as it was at any point: `SELECT * FROM tbl AT (TIMESTAMP => '2025-01-01')`. Critical for reproducible analysis | LOW (built-in) | DuckLake provides this for free via snapshot architecture. No extra implementation needed beyond keeping snapshots |
| **DuckLake data change feed** | Analysts can see exactly what changed between refreshes: `table_changes('tbl', start, end)`. Answers "what's new since I last looked?" | LOW (built-in) | Built into DuckLake. Returns `insert/update_preimage/update_postimage/delete` per row |
| **Spatial data as native geometry** | DuckLake supports geometry types natively in parquet (point, polygon, multipolygon etc.). Analysts can query boundaries without WKB blob manipulation | MEDIUM | Source data uses WKB_BLOB. Need to convert to DuckLake's native geometry types during export. DuckDB spatial extension handles conversion |
| **Schema evolution** | Adding/removing/renaming columns without breaking existing queries or analyst scripts | LOW (built-in) | DuckLake handles this transparently: old parquet files coexist with new schema via field ID remapping |
| **Automated refresh workflow** | Script to re-export updated tables on a schedule (quarterly/annual refreshes) | MEDIUM | Not built into DuckLake. Needs a Python script that detects changes in source DuckDB and runs `MERGE INTO` or full table replacement |
| **DuckLake views** | Pre-built useful queries stored in the catalogue (e.g., "IMD deciles for WECA area only") | LOW | `CREATE VIEW` supported in DuckLake. Views stored in metadata and available to all attached clients |
| **Direct S3 parquet access** | Analysts who don't want DuckLake overhead can read parquet files directly: `read_parquet('s3://bucket/schema/table/*.parquet')` | LOW | Works by default since DuckLake writes standard parquet files to predictable S3 paths |
| **Data catalogue manifest** | A queryable table-of-tables with descriptions, row counts, last updated dates, column listings | MEDIUM | Can be built as a DuckLake view over the metadata tables (`ducklake_table`, `ducklake_column`, `ducklake_snapshot`). For pins users, generate a static manifest file |

### Anti-Features (Commonly Requested, Often Problematic)

Features that seem good but create problems for a small team of analysts.

| Feature | Why Requested | Why Problematic | Alternative |
|---------|---------------|-----------------|-------------|
| **Web UI / data browser** | "Wouldn't it be nice to browse data in a browser?" | Massive engineering effort for a small team. Maintenance burden. Analysts already have R/Python notebooks | Provide a notebook template that lists all tables with descriptions. DuckDB CLI works for quick exploration |
| **Real-time data sync** | "Can the shared data update automatically when the source changes?" | Source DuckDB is manually curated. Real-time adds complexity (CDC, streaming) for data that updates quarterly. Fragile infrastructure for no real benefit | Manual or scheduled batch refresh. A simple Python script run when source data updates |
| **Write access for analysts** | "Can I save my derived tables back to the shared catalogue?" | Creates data governance problems. Who owns derived data? Version conflicts. Quality control disappears | Analysts work locally. If derived data is valuable, the data curator (you) adds it to the source DuckDB after review |
| **PostgreSQL metadata catalogue** | "DuckLake docs recommend PostgreSQL for multi-user metadata" | For 5-15 analysts doing read-only queries, DuckDB file-based metadata on S3 is sufficient. PostgreSQL adds a server to maintain, network dependency, cost | Start with DuckDB-backed metadata. DuckLake can migrate to PostgreSQL later if concurrent write conflicts become a problem (they won't for read-only use) |
| **Fine-grained per-table access control** | "Different analysts should see different tables" | For a small team sharing public/internal government data, this adds complexity without value. All 18 tables are intended for the whole team | Keep it simple: one reader role, all tables visible. If genuinely sensitive data appears later, use DuckLake schema-level S3 IAM policies |
| **DuckLake encryption** | "Encrypt all data at rest" | S3 already provides server-side encryption (SSE-S3 or SSE-KMS). DuckLake encryption adds key management complexity and breaks direct parquet reading | Use S3 server-side encryption. All data is internal government statistics, not PII |
| **Data inlining** | DuckLake feature to store small datasets in metadata DB | Experimental feature (confirmed in docs). Breaks the simple "all data is parquet on S3" model. Adds complexity for marginal benefit with batch-loaded data | Write all data as parquet files. Use `merge_adjacent_files` for compaction if small files accumulate |
| **Partitioning** | "Partition large tables by date/region for performance" | Only one table (EPCs at 19M rows) is large enough to benefit. Partitioning adds complexity to the refresh workflow and the mental model for analysts | Start without partitioning. If EPC query performance is poor, partition that single table later. DuckLake supports adding partitions after the fact |

## Feature Dependencies

```
[S3 Parquet Export]
    |
    ├──enables──> [Pins R Access]
    ├──enables──> [Pins Python Access]
    ├──enables──> [Direct S3 Parquet Access]
    └──enables──> [DuckLake Catalogue]
                      |
                      ├──enables──> [Time Travel]
                      ├──enables──> [Data Change Feed]
                      ├──enables──> [Schema Evolution]
                      ├──enables──> [Views]
                      ├──enables──> [COMMENT ON Metadata]
                      └──enables──> [Data Catalogue Manifest]

[Metadata Preservation]
    └──requires──> [S3 Parquet Export] (comments must be written during export)

[Spatial Geometry Conversion]
    └──requires──> [S3 Parquet Export] (WKB_BLOB → native geometry during export)

[Automated Refresh Workflow]
    └──requires──> [S3 Parquet Export] + [DuckLake Catalogue]

[AWS Credential Setup]
    └──required-by──> [ALL access patterns] (pins, DuckLake, direct S3)

[Read-Only Access Control]
    └──required-by──> [ALL analyst access] (IAM policies + DuckLake reader role)
```

### Dependency Notes

- **Everything requires S3 Parquet Export:** This is the foundational capability. Nothing works without data on S3.
- **DuckLake enables the advanced features for free:** Time travel, change feed, schema evolution, views, and comments all come automatically once DuckLake is set up. No incremental implementation cost.
- **Pins and DuckLake are parallel access paths:** They don't depend on each other. Pins gives immediate value; DuckLake gives richer querying.
- **Spatial geometry conversion blocks on export design:** Must decide during the export phase whether to convert WKB_BLOB to native geometry or leave as blob. Native geometry is strongly preferred as DuckLake has native support.
- **Automated refresh requires both export and DuckLake:** Needs the export pipeline (to know how to write data) and DuckLake's `MERGE INTO` or table replacement for clean updates.

## MVP Definition

### Launch With (v1)

Minimum viable: analysts can access shared data from R or Python.

- [ ] **S3 parquet export pipeline** -- without this, nothing exists to share
- [ ] **Metadata preservation** (table + column comments) -- without this, data is undocumented and useless
- [ ] **R access via pins** -- half the team's workflow
- [ ] **Python access via pins** -- other half's workflow
- [ ] **AWS credential documentation for readers** -- analysts cannot access data without this
- [ ] **Read-only IAM policy for analyst AWS users** -- data integrity protection

### Add After Validation (v1.x)

Features to add once core export + pins access is working.

- [ ] **DuckLake catalogue setup** -- trigger: analysts want richer querying than `pin_read()` provides (joins, filters, SQL)
- [ ] **COMMENT ON metadata in DuckLake** -- trigger: DuckLake is attached, carry over all source comments
- [ ] **Spatial geometry conversion** -- trigger: analysts need to use boundary/postcode geometry data for mapping
- [ ] **DuckLake views** -- trigger: common queries keep being repeated across the team
- [ ] **Data catalogue manifest** -- trigger: new team members ask "what data is available?"

### Future Consideration (v2+)

Features to defer until the platform is in active daily use.

- [ ] **Automated refresh workflow** -- defer: manual refresh is fine while establishing the platform. Automate once the refresh cadence is clear
- [ ] **DuckLake data change feed usage** -- defer: only valuable once multiple refresh cycles have occurred
- [ ] **Time travel queries** -- defer: built-in to DuckLake, but only useful once there's history to travel through
- [ ] **PostgreSQL metadata backend** -- defer: only needed if concurrent write access becomes a problem (unlikely for read-only analyst use)
- [ ] **Table partitioning for EPCs** -- defer: only if query performance on the 19M row table is problematic

## Feature Prioritisation Matrix

| Feature | User Value | Implementation Cost | Priority |
|---------|------------|---------------------|----------|
| S3 parquet export | HIGH | MEDIUM | P1 |
| Metadata preservation | HIGH | MEDIUM | P1 |
| R access (pins) | HIGH | LOW | P1 |
| Python access (pins) | HIGH | LOW | P1 |
| AWS credential setup (readers) | HIGH | LOW | P1 |
| Read-only access control | HIGH | LOW | P1 |
| DuckLake catalogue setup | HIGH | MEDIUM | P2 |
| COMMENT ON in DuckLake | MEDIUM | LOW | P2 |
| Spatial geometry conversion | MEDIUM | MEDIUM | P2 |
| Data catalogue manifest | MEDIUM | MEDIUM | P2 |
| DuckLake views | MEDIUM | LOW | P2 |
| Automated refresh workflow | MEDIUM | MEDIUM | P3 |
| Data change feed usage | LOW | LOW | P3 |
| Time travel | LOW | LOW (free) | P3 |
| Table partitioning (EPCs) | LOW | MEDIUM | P3 |

**Priority key:**
- P1: Must have for launch -- analysts cannot work without these
- P2: Should have, add once P1 is validated -- makes the platform significantly better
- P3: Nice to have, future consideration -- valuable but not urgent

## Competitor/Alternative Feature Analysis

| Feature | Shared Network Drive | Manual S3 + Parquet | Pins on S3 | DuckLake on S3 | Our Approach |
|---------|---------------------|---------------------|------------|----------------|--------------|
| Data access | Copy files locally | `read_parquet('s3://...')` | `pin_read('table_name')` | `SELECT * FROM table` | Both pins (simple) and DuckLake (powerful) |
| Metadata/docs | Separate README | None (file names only) | Pin title + description | `COMMENT ON TABLE/COLUMN` | Rich metadata at every layer |
| Versioning | Manual file copies | None | Pin versioning (basic) | Full snapshot-based time travel | DuckLake snapshots for audit trail |
| Discovery | Browse folder | `ls` the bucket | `pin_list(board)` | `SHOW TABLES; DESCRIBE table` | Catalogue manifest + DuckLake metadata |
| Schema changes | Break consumers | Break consumers | Break consumers | Transparent schema evolution | DuckLake handles gracefully |
| Spatial data | Shapefiles | GeoParquet (manual) | Parquet blobs | Native geometry types | DuckLake native geometry |
| Refresh tracking | "v2_final_FINAL.csv" | Overwrite and hope | Pin versions with dates | Change feed between snapshots | DuckLake change feed |
| Access control | Folder permissions | IAM policies (coarse) | IAM policies | IAM + catalogue permissions | IAM reader policy + DuckLake reader role |

## Sources

- DuckLake documentation (local: `docs/ducklake-docs.md`) -- verified features: geometry types, time travel, data change feed, COMMENT ON, views, access control, schema evolution, data inlining, encryption, secrets, merge/upsert, maintenance functions
- Project context: `README.md`, `PROJECT.md`, `aws_setup.r`, `pyproject.toml`
- DuckLake specification v0.3 (from docs) -- verified: snapshot architecture, tag/column_tag tables, metadata schema

**Confidence notes:**
- HIGH confidence on DuckLake features (verified directly against official docs)
- MEDIUM confidence on pins capabilities (based on project's working R code and Python dependency; did not verify pins Python docs directly)
- LOW confidence on spatial conversion path (WKB_BLOB to DuckLake native geometry) -- needs phase-specific research when implementing

---
*Feature research for: DuckDB-to-S3 data sharing platform (WECA analyst team)*
*Researched: 2026-02-22*
