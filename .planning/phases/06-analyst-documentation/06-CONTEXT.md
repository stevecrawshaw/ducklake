# Phase 6: Analyst Documentation - Context

**Gathered:** 2026-02-25
**Status:** Ready for planning

<domain>
## Phase Boundary

Single comprehensive guide enabling WECA analysts to go from zero to querying data independently. Covers package installation, AWS credential setup, pins access (R primary, Python appendix), DuckLake catalogue queries, and spatial data. Delivered as a Quarto document with WECA branding, rendering to both HTML and PDF (via branded typst template).

</domain>

<decisions>
## Implementation Decisions

### Audience & prerequisites
- Primary audience: internal WECA staff, mainly R/tidyverse analysts
- Assume nothing: cover R/Python package installation, DuckDB installation, and basic SQL orientation
- Include AWS credential setup (how to request access, configure locally, verify connectivity)
- Can reference internal systems, Slack channels, and team contacts

### Document structure & format
- Single combined guide covering everything: setup, pins, DuckLake, spatial
- Quarto document (.qmd) rendering to HTML and PDF
- PDF output via branded typst template (https://github.com/stevecrawshaw/typst-template)
- HTML output with WECA corporate branding (use /weca-branding skill)
- R is the primary language throughout the guide
- Python equivalents provided in an appendix section
- Include both: a quick summary table of all 18 datasets in the doc + instructions on querying the DuckLake catalogue programmatically for full details

### Code examples depth
- All code examples executable Quarto chunks with visible output
- Cover: connection, reading tables, filtering, joining, aggregation, spatial operations
- Dedicated spatial section: reading GeoParquet, converting to sf/geopandas, plotting a quick map
- Time travel: brief mention with syntax example, not a full section
- CRS note for spatial data: analysts must set CRS explicitly (DuckDB GeoParquet doesn't embed it)

### Discoverability & onboarding flow
- Docs live in the GitHub repo (primary distribution)
- Include support contact info (Slack channel or named person for data platform questions)

### Claude's Discretion
- Document flow structure (linear tutorial vs quick-start + reference — decide based on what works best for the content)
- Troubleshooting approach (dedicated section vs inline tips — decide based on likely pain points)
- Exact section ordering and headings
- Level of SQL primer coverage (enough to get started, not a SQL course)

</decisions>

<specifics>
## Specific Ideas

- Use the branded typst template at https://github.com/stevecrawshaw/typst-template for PDF rendering
- Apply WECA branding via the /weca-branding skill for HTML output
- sfarrow fails on DuckDB GeoParquet (missing CRS) — document the arrow::read_parquet + sf::st_as_sf workaround
- Python pins board_s3 uses "bucket/prefix" format — document this clearly
- 10-minute success criterion: an unfamiliar analyst should be able to follow the docs and read a dataset within 10 minutes

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 06-analyst-documentation*
*Context gathered: 2026-02-25*
