# Phase 4: Spatial Data Handling - Context

**Gathered:** 2026-02-23
**Status:** Ready for planning

<domain>
## Phase Boundary

Convert WKB_BLOB geometry columns in the 8 spatial tables so they are accessible through both pins (as GeoParquet) and DuckLake (as native GEOMETRY if supported). Analysts should be able to read spatial data in R sf, Python geopandas, and run spatial SQL queries in DuckLake. The 3 deferred spatial views from Phase 3 are NOT in scope — defer to a later phase.

</domain>

<decisions>
## Implementation Decisions

### Spatial format strategy
- GeoParquet is the preferred format for pins exports
- DuckLake format is Claude's discretion — use native GEOMETRY if DuckLake supports it, otherwise research the best option
- If GeoParquet doesn't work with pins (e.g. pin_upload incompatibility), fall back to WKT text column
- CRS handling is Claude's discretion — research what the source tables use and recommend

### Analyst consumption patterns
- Analysts need full spatial capability: plotting maps, spatial joins/queries, and GIS tool export
- Spatial SQL in DuckLake is desired — analysts should be able to write ST_Contains(), ST_Intersects() queries directly against DuckLake tables
- Code examples for spatial tables are deferred to Phase 6 (Analyst Documentation)
- Validation scope (which tools must roundtrip successfully) is Claude's discretion based on what's feasible

### Geometry validation & edge cases
- Invalid geometries: flag and include — add a validity column so analysts can filter, but don't silently repair
- NULL/empty geometries: include rows with NULL geometry column, don't exclude
- Mixed geometry types: promote to Multi variant (POLYGON → MULTIPOLYGON) for consistency
- Logging: minimal — only log errors, not successful conversions

### Spatial table scope
- Whether to spike with 1 table first or batch all 8 is Claude's discretion based on research findings
- The 3 deferred spatial views from Phase 3 remain deferred — not in this phase
- Table sizes are unknown — research should check for any large tables that need chunked processing
- Spatial pins should be distinguished from non-spatial pins with a marker (suffix or metadata tag) so analysts can identify which pins have geometry

### Claude's Discretion
- DuckLake spatial format (native GEOMETRY vs alternative)
- CRS selection and whether to re-project
- Spike-first vs batch-all approach
- Validation tool scope (sf + geopandas + DuckDB spatial, or subset)
- Specific pin naming/tagging convention for spatial pins

</decisions>

<specifics>
## Specific Ideas

- User wants spatial SQL queries (ST_Contains, ST_Intersects) to work directly in DuckLake — this is a strong preference, not just nice-to-have
- GeoParquet chosen specifically because sf and geopandas read it natively — analyst friction should be minimal
- Invalid geometries should be visible (flagged), not hidden — analysts may want to inspect or fix them

</specifics>

<deferred>
## Deferred Ideas

- 3 spatial-dependent views from Phase 3 — defer to Phase 5 or later
- Per-table spatial code examples — Phase 6 (Analyst Documentation)

</deferred>

---

*Phase: 04-spatial-data-handling*
*Context gathered: 2026-02-23*
