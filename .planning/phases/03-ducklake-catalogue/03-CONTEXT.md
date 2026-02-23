# Phase 3: DuckLake Catalogue - Context

**Gathered:** 2026-02-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Register all 18 tables (10 non-spatial + 8 spatial) in a single DuckLake catalogue with table/column comments, time travel, and pre-built views. Analysts attach one catalogue and query any table with SQL. Spatial geometry conversion is out of scope (Phase 4) — spatial tables are registered but geometry columns remain as-is.

</domain>

<decisions>
## Implementation Decisions

### Catalogue structure
- Single DuckLake catalogue for all 18 tables
- Flat schema layout (all tables in default/main schema)
- Include DuckLake extension setup steps so the catalogue works end-to-end for analysts
- Metadata database location: Claude's discretion based on analyst access patterns

### Table & column comments
- Copy existing descriptions verbatim from the source DuckDB — no enrichment
- Description only in column comments (no data type info — analysts use DESCRIBE)
- Leave comments empty where source has no description (no placeholders)
- Purely descriptive table comments — no row counts or data freshness stats

### Pre-built views
- Include existing views from the source database (they use `_vw` suffix convention)
- Create WECA-filtered views for applicable tables using `_weca_vw` suffix (e.g., `epc_certificates_weca_vw`)
- WECA filter covers: Bath & NE Somerset, Bristol, North Somerset, South Gloucestershire
- Which tables get WECA views: Claude's discretion based on which tables have filterable geography columns

### Time travel
- Limited retention: keep last 5 versions per table
- Time travel surfacing and change data feed: Claude's discretion based on what DuckLake provides natively

### Claude's Discretion
- DuckLake metadata database location (S3 vs local)
- Which tables get WECA-filtered views (based on geography column presence)
- Time travel discoverability (core feature vs safety net)
- Whether to expose DuckLake's data change feed
- Any technical implementation details

</decisions>

<specifics>
## Specific Ideas

- Existing views in the source database already use `_vw` suffix — maintain this convention
- WECA authorities: Bath & NE Somerset, Bristol, North Somerset, South Gloucestershire

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 03-ducklake-catalogue*
*Context gathered: 2026-02-23*
