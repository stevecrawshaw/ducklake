# Plan 01-01 Summary: IAM Policy and DuckDB Verification Script

**Phase:** 01-aws-infrastructure
**Plan:** 01-01
**Status:** Complete
**Completed:** 2026-02-22

## What was built

- `iam/ducklake-s3-reader-policy.json` — customer-managed IAM policy granting read-only S3 access to `stevecrawshaw-bucket` (bucket-level and object-level statements)
- `scripts/setup_iam.sh` — AWS CLI script creating the policy, group (`ducklake-readers`), user (`ducklake-analyst`), and access key
- `scripts/verify_s3_access.sql` — DuckDB SQL using `credential_chain` (no hardcoded keys) to verify S3 connectivity with explicit `eu-west-2` region override

## Human actions completed

- Admin AWS credentials configured in `~/.aws/credentials`
- `bash scripts/setup_iam.sh` run successfully
- `ducklake-s3-reader` policy, `ducklake-readers` group, and `ducklake-analyst` user created in AWS account `870381419052`
- Access key generated and saved to Keeper

## Notes

- `sh scripts/setup_iam.sh` fails due to `pipefail` not supported by `sh` — must use `bash`
- Script is not idempotent; re-running will produce `EntityAlreadyExists` errors (expected)
- Explicit `REGION` in the DuckDB secret is required — DuckDB does not reliably read region from `~/.aws/config`

## Success criteria met

- [x] IAM policy `ducklake-s3-reader` exists in the AWS account
- [x] IAM group `ducklake-readers` exists with policy attached
- [x] IAM user `ducklake-analyst` exists in `ducklake-readers` group
- [x] Access key generated and stored in Keeper
- [x] `scripts/verify_s3_access.sql` created for data owner to verify DuckDB-to-S3 connectivity
