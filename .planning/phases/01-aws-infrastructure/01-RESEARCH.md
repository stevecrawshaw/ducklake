# Phase 1: AWS Infrastructure - Research

**Researched:** 2026-02-22
**Domain:** AWS IAM, S3 access control, DuckDB credential management
**Confidence:** HIGH

## Summary

Phase 1 establishes the AWS access layer: a read-only IAM policy scoped to `stevecrawshaw-bucket`, a shared IAM user with long-lived access keys for analysts, and the DuckDB `credential_chain` configuration for the data owner. No data is exported in this phase.

The standard approach is straightforward: create an IAM policy with `s3:GetObject` and `s3:ListBucket`, attach it to an IAM group, create a single shared IAM user within that group, generate access keys, and distribute them via Keeper. DuckDB's `credential_chain` provider with `CHAIN config` reads credentials from `~/.aws/credentials` automatically.

This is well-trodden territory with minimal technical risk. The main pitfall is getting the IAM policy ARN format wrong (bucket-level vs object-level resources).

**Primary recommendation:** Use an IAM group with an inline or customer-managed policy, a single IAM user for analysts, and DuckDB `credential_chain` with explicit `REGION 'eu-west-2'` override.

## Standard Stack

### Core

| Tool | Version | Purpose | Why Standard |
|------|---------|---------|--------------|
| AWS CLI | v2 | IAM user/group/policy creation | Official AWS management tool |
| AWS IAM | N/A | Identity and access management | AWS-native access control |
| DuckDB | >=1.4.4 | S3 data querying with credential_chain | Already in project dependencies |
| DuckDB `aws` extension | Auto-loaded | credential_chain provider | Official DuckDB extension for AWS auth |

### Supporting

| Tool | Purpose | When to Use |
|------|---------|-------------|
| `paws.storage` (R) | S3 access from R via pins | Analysts using `board_s3()` in R |
| `boto3` (Python) | S3 access from Python | Already in project dependencies |
| Keeper | Credential storage and distribution | Sharing access keys with analysts |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Shared IAM user | Per-analyst IAM users | Better audit trail, but unnecessary overhead for 2-5 analysts with read-only access to public statistics |
| Long-lived access keys | IAM roles with STS | More secure, but requires SSO/federation infrastructure that does not exist |
| IAM group + user | AWS managed policy `AmazonS3ReadOnlyAccess` | Simpler, but grants access to ALL S3 buckets across the account, not just the target bucket |

## Architecture Patterns

### Recommended IAM Structure

```
AWS Account
  |-- IAM Policy: ducklake-s3-reader (customer-managed)
  |     s3:GetObject on arn:aws:s3:::stevecrawshaw-bucket/*
  |     s3:ListBucket on arn:aws:s3:::stevecrawshaw-bucket
  |
  |-- IAM Group: ducklake-readers
  |     Policy attached: ducklake-s3-reader
  |
  |-- IAM User: ducklake-analyst (shared)
        Member of: ducklake-readers
        Access key: generated, stored in Keeper
```

### Pattern 1: Customer-Managed Policy (not inline)

**What:** Create a named, reusable policy rather than an inline policy on the group.
**When to use:** Always for this use case -- allows the policy to be viewed, versioned, and reattached independently.
**Why:** If in future you need per-analyst users, the same policy attaches to each. Inline policies cannot be reused.

### Pattern 2: DuckDB credential_chain with explicit region

**What:** Use `credential_chain` with `CHAIN config` and an explicit `REGION` override.
**When to use:** When the `~/.aws/config` file may not have the region set, or when you want the DuckDB secret to be self-documenting.
**Why:** DuckDB has known issues where the region is not always picked up from the config file. Explicit region avoids silent failures.

### Anti-Patterns to Avoid

- **Hardcoded keys in code:** Never put `KEY_ID` and `SECRET` directly in DuckDB `CREATE SECRET` statements or Python/R scripts. Use `credential_chain` instead.
- **Using `AmazonS3ReadOnlyAccess` managed policy:** Grants read access to every S3 bucket in the account. Always scope to the specific bucket.
- **Putting both bucket-level and object-level actions on the same Resource ARN:** `s3:ListBucket` operates on the bucket ARN (no `/*`), `s3:GetObject` operates on the object ARN (with `/*`). Mixing these causes access denied errors.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| AWS credential lookup | Custom config file parsers | `credential_chain` provider in DuckDB, `paws` credential chain in R, `boto3` default chain in Python | All three tools already implement the standard AWS credential provider chain |
| Access key distribution | Email, Slack, or plaintext file | Keeper password manager | Secure channel already in use by the team |
| Policy validation | Manual testing only | `aws iam simulate-principal-policy` or `aws s3 ls` test | Automated verification catches policy errors immediately |

**Key insight:** The entire AWS credential chain is standardised. DuckDB, R (`paws`), Python (`boto3`), and the AWS CLI all look in `~/.aws/credentials` and `~/.aws/config` by default. Configure once, works everywhere.

## Common Pitfalls

### Pitfall 1: Wrong ARN format for ListBucket vs GetObject

**What goes wrong:** Policy grants `s3:ListBucket` on `arn:aws:s3:::stevecrawshaw-bucket/*` (with wildcard) instead of `arn:aws:s3:::stevecrawshaw-bucket` (without wildcard). Result: `Access Denied` when listing bucket contents.
**Why it happens:** Developers assume all S3 actions use the same ARN format.
**How to avoid:** Two separate statements in the policy: bucket-level actions use the bucket ARN, object-level actions use the bucket ARN with `/*` suffix.
**Warning signs:** `aws s3 ls s3://stevecrawshaw-bucket/` returns `Access Denied` but `aws s3 cp s3://stevecrawshaw-bucket/file.parquet .` works.

### Pitfall 2: DuckDB region not picked up from config

**What goes wrong:** DuckDB credential_chain creates a secret but targets `us-east-1` (default) instead of `eu-west-2`, causing `403 Forbidden` or redirect errors when querying S3.
**Why it happens:** The region in `~/.aws/config` is not always read by DuckDB's credential chain, especially if the config file uses `[profile name]` format rather than `[default]`.
**How to avoid:** Always specify `REGION 'eu-west-2'` explicitly in the `CREATE SECRET` statement.
**Warning signs:** HTTP 301 redirect errors or `403` when querying S3 paths that definitely exist.

### Pitfall 3: Credentials file vs config file confusion

**What goes wrong:** Analyst puts region in `~/.aws/credentials` instead of `~/.aws/config`, or uses `[profile myprofile]` syntax in credentials file (should be just `[myprofile]`).
**Why it happens:** AWS uses two different files with slightly different syntax rules.
**How to avoid:** Documentation must clearly show both files with exact syntax. Credentials file uses `[profile-name]`, config file uses `[profile profile-name]` (with prefix).
**Warning signs:** `aws s3 ls` works but DuckDB or R fail to authenticate.

### Pitfall 4: Forgetting s3:GetBucketLocation

**What goes wrong:** Some tools (including older versions of paws) call `GetBucketLocation` before making requests. Without this permission, they fail silently or with cryptic errors.
**Why it happens:** Not all S3 clients need this, so it is easy to omit.
**How to avoid:** Include `s3:GetBucketLocation` in the policy alongside `s3:ListBucket`. Minimal cost, prevents obscure failures.
**Warning signs:** R `board_s3()` fails on initial connection but `aws s3 ls` works.

### Pitfall 5: DuckDB VALIDATION default requires credentials at creation time

**What goes wrong:** `CREATE SECRET` with `credential_chain` fails if no credentials are present when the statement runs (e.g. in a shared script or notebook).
**Why it happens:** Since DuckDB v1.4.1, the default validation mode is `VALIDATION 'exists'`, which checks credentials exist at secret creation time.
**How to avoid:** Either ensure credentials are configured before running the statement, or use `VALIDATION 'none'` if creating a template script.
**Warning signs:** Error message about missing credentials when creating the secret.

## Code Examples

### IAM Policy JSON (customer-managed)

```json
// Source: AWS IAM documentation - identity-based policy examples
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowListBucket",
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::stevecrawshaw-bucket"
        },
        {
            "Sid": "AllowGetObject",
            "Effect": "Allow",
            "Action": "s3:GetObject",
            "Resource": "arn:aws:s3:::stevecrawshaw-bucket/*"
        }
    ]
}
```

### AWS CLI: Create policy, group, user, and access key

```bash
# Source: AWS CLI IAM documentation
# 1. Create the policy from a JSON file
aws iam create-policy \
    --policy-name ducklake-s3-reader \
    --policy-document file://ducklake-s3-reader-policy.json

# 2. Create the group
aws iam create-group --group-name ducklake-readers

# 3. Attach the policy to the group
# (use the ARN returned from create-policy)
aws iam attach-group-policy \
    --group-name ducklake-readers \
    --policy-arn arn:aws:iam::ACCOUNT_ID:policy/ducklake-s3-reader

# 4. Create the shared analyst user
aws iam create-user --user-name ducklake-analyst

# 5. Add user to group
aws iam add-user-to-group \
    --user-name ducklake-analyst \
    --group-name ducklake-readers

# 6. Generate access keys (save output securely!)
aws iam create-access-key --user-name ducklake-analyst
```

### Analyst ~/.aws/credentials file

```ini
# Source: AWS CLI configuration documentation
[default]
aws_access_key_id = <YOUR_ACCESS_KEY_ID>
aws_secret_access_key = <YOUR_SECRET_ACCESS_KEY>
```

### Analyst ~/.aws/config file

```ini
# Source: AWS CLI configuration documentation
[default]
region = eu-west-2
output = json
```

### DuckDB credential_chain setup (data owner and analysts)

```sql
-- Source: https://duckdb.org/docs/stable/core_extensions/aws
-- Works for both data owner and analysts
-- Reads credentials from ~/.aws/credentials automatically
CREATE OR REPLACE SECRET ducklake_s3 (
    TYPE s3,
    PROVIDER credential_chain,
    CHAIN config,
    REGION 'eu-west-2'
);

-- Verify: list files in the bucket
SELECT * FROM glob('s3://stevecrawshaw-bucket/*');
```

### R pins board_s3 setup (analyst verification)

```r
# Source: https://pins.rstudio.com/reference/board_s3.html
# Uses paws credential chain - reads ~/.aws/credentials automatically
library(pins)

board <- board_s3(
    bucket = "stevecrawshaw-bucket",
    region = "eu-west-2"
)

# Verify access
pin_list(board)
```

### Python boto3 verification (analyst)

```python
# Source: boto3 documentation
# Uses default credential chain - reads ~/.aws/credentials automatically
import boto3

s3 = boto3.client("s3", region_name="eu-west-2")
response = s3.list_objects_v2(Bucket="stevecrawshaw-bucket", MaxKeys=5)
for obj in response.get("Contents", []):
    print(obj["Key"])
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Hardcoded keys in `CREATE SECRET` | `credential_chain` provider | DuckDB 0.10+ | No secrets in code; standard AWS config works |
| `httpfs` extension manual config | `aws` extension with auto-load | DuckDB 1.0+ | Extensions auto-install and auto-load transparently |
| `VALIDATION 'none'` default | `VALIDATION 'exists'` default | DuckDB 1.4.1 | Credentials must exist at secret creation time (safer default) |

**Deprecated/outdated:**
- DuckDB `s3_access_key_id` / `s3_secret_access_key` settings: replaced by `CREATE SECRET` mechanism
- R `aws.s3` package: the project's `aws_setup.r` uses it, but `paws.storage` (via pins `board_s3`) is the modern approach already in use

## Open Questions

1. **Data owner's existing AWS profile name**
   - What we know: Data owner uses `~/.aws/credentials` (confirmed in CONTEXT.md)
   - What is unclear: Whether it is the `[default]` profile or a named profile
   - Recommendation: Check the data owner's `~/.aws/credentials` and `~/.aws/config` files before creating the DuckDB secret. If a named profile is used, add `PROFILE 'profile-name'` to the `CREATE SECRET` statement.

2. **AWS account ID for policy ARN**
   - What we know: The bucket `stevecrawshaw-bucket` exists in `eu-west-2`
   - What is unclear: The AWS account ID needed for the policy ARN in `attach-group-policy`
   - Recommendation: Retrieve with `aws sts get-caller-identity` during implementation.

3. **Whether analysts need AWS CLI installed**
   - What we know: Analysts need `~/.aws/credentials` and `~/.aws/config` files
   - What is unclear: Whether to have analysts install the AWS CLI or just manually create the files
   - Recommendation: Manual file creation is simpler for a small team. The AWS CLI is useful for verification (`aws s3 ls`) but not strictly required -- DuckDB, R pins, and Python boto3 all read the credential files directly.

## Sources

### Primary (HIGH confidence)
- [DuckDB AWS extension docs](https://duckdb.org/docs/stable/core_extensions/aws) - credential_chain provider, CHAIN options, REGION override, VALIDATION modes
- [DuckDB S3 API docs](https://duckdb.org/docs/stable/core_extensions/httpfs/s3api) - S3 secret configuration, credential_chain profiles
- Context7 `/websites/duckdb_stable` - credential_chain code examples, verified against official docs
- [AWS IAM identity-based policy examples](https://docs.aws.amazon.com/AmazonS3/latest/userguide/example-policies-s3.html) - S3 read-only policy JSON structure
- [AWS IAM access keys documentation](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html) - access key creation and best practises
- [AWS CLI configuration and credential files](https://docs.aws.amazon.com/cli/v1/userguide/cli-configure-files.html) - file format, profile syntax
- [R pins board_s3 reference](https://pins.rstudio.com/reference/board_s3.html) - paws credential chain, board_s3 parameters

### Secondary (MEDIUM confidence)
- [AWS IAM CLI cheatsheet](https://blog.leapp.cloud/aws-iam-cli-a-cheatsheet) - CLI command sequence for user/group/policy creation
- [AWS S3 ListBucket ARN fix](https://openillumi.com/en/en-fix-s3-iam-listbucket-resource-error/) - bucket-level vs object-level ARN pitfall
- [DuckDB GitHub Discussion #10696](https://github.com/duckdb/duckdb/discussions/10696) - region mismatch issues with credential_chain

### Tertiary (LOW confidence)
- None -- all findings verified against primary sources

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - All tools are official AWS and DuckDB components, verified against current documentation
- Architecture: HIGH - IAM group/user/policy pattern is standard AWS practice documented extensively
- Pitfalls: HIGH - ARN format issue is well-documented; DuckDB region issue confirmed in GitHub discussions and official docs

**Research date:** 2026-02-22
**Valid until:** 2026-04-22 (stable domain -- AWS IAM and DuckDB credential_chain are mature features)
