# Phase 1: AWS Infrastructure - Context

**Gathered:** 2026-02-22
**Status:** Ready for planning

<domain>
## Phase Boundary

Read-only IAM policy and credential configuration so analysts can access S3 data, and the data owner has a secure write-access foundation for all subsequent export operations. This phase does NOT export any data — it establishes the access layer.

</domain>

<decisions>
## Implementation Decisions

### IAM Policy Design
- Single shared reader role for all analysts (not per-user IAM users)
- Read + list only: `s3:GetObject` and `s3:ListBucket` on entire bucket (`stevecrawshaw-bucket/*`)
- Entire bucket scope — all data is intended for the team, no prefix-level restrictions needed
- Starting fresh — no existing IAM roles or users to build on

### Credential Distribution
- Small team (2-5 analysts), manual credential handoff via secure channel
- Long-lived access keys are acceptable — read-only access to non-sensitive government statistics
- Analysts store credentials in `~/.aws/credentials` file (standard AWS config, works with pins, DuckDB, and CLI)
- No credential rotation requirement for v1

### S3 Bucket Layout
- Use existing `stevecrawshaw-bucket` in `eu-west-2` (London)
- Top-level prefix split: `ducklake/` for DuckLake files, `pins/` for pins-published datasets
- Existing files in the bucket must be preserved (including imd2025 parquet from earlier work)
- No nesting under a data/ prefix — keep it flat and simple

### Data Owner Workflow
- Data owner authenticates via `~/.aws/credentials` file (existing setup)
- AWS profile to be determined (check existing config — may be default or named)
- DuckDB secrets: use `credential_chain` provider (picks up from .aws config automatically, no keys in code)
- Write access scope: broader IAM permissions exist; the reader policy is what restricts analysts

### Claude's Discretion
- Exact IAM policy JSON structure
- Whether to use IAM user or IAM role for the shared reader
- AWS profile naming conventions
- DuckDB secret creation syntax and credential_chain configuration

</decisions>

<specifics>
## Specific Ideas

- Credentials are managed in Keeper (password manager) — could be the secure handoff channel
- The aws_setup.r script already demonstrates working S3 connectivity from R

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope

</deferred>

---

*Phase: 01-aws-infrastructure*
*Context gathered: 2026-02-22*
