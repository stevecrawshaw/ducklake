# AWS Credential Setup for DuckLake Analysts

This guide walks you through configuring AWS credentials on your machine so you can access the shared S3 bucket (`stevecrawshaw-bucket`) from DuckDB, R, or Python.

## Prerequisites

- You have received an AWS access key ID and secret access key from the data owner (via Keeper).
- You have DuckDB installed (for SQL access), and/or R with the `pins` package, and/or Python with `boto3`.
- No AWS CLI installation is required, though it is useful for troubleshooting.

## Step 1: Create the credentials file

Create the file at:

- **Linux/Mac:** `~/.aws/credentials`
- **Windows:** `C:\Users\USERNAME\.aws\credentials`

If the `.aws` directory does not exist, create it first.

Paste the following content, replacing the placeholders with your actual keys:

```ini
[default]
aws_access_key_id = <YOUR_ACCESS_KEY_ID>
aws_secret_access_key = <YOUR_SECRET_ACCESS_KEY>
```

## Step 2: Create the config file

Create the file at:

- **Linux/Mac:** `~/.aws/config`
- **Windows:** `C:\Users\USERNAME\.aws\config`

Paste the following content:

```ini
[default]
region = eu-west-2
output = json
```

**The region must be `eu-west-2` (London).** The S3 bucket is in this region. Using any other region will cause errors or redirects.

## Step 3: Verify access

Pick whichever tool you use day-to-day. A successful result from any one method confirms your credentials are working.

### DuckDB

The repository includes a verification script at `scripts/verify_s3_access.sql`. You can also run the following directly:

```sql
INSTALL aws;
LOAD aws;

CREATE OR REPLACE SECRET ducklake_s3 (
    TYPE s3,
    PROVIDER credential_chain,
    CHAIN config,
    REGION 'eu-west-2'
);

SELECT * FROM glob('s3://stevecrawshaw-bucket/*');
```

**Expected:** A table listing files in the bucket.

### R (pins)

```r
library(pins)
board <- board_s3(bucket = "stevecrawshaw-bucket", region = "eu-west-2")
pin_list(board)
```

**Expected:** A character vector of pin names. This may be empty if no pins have been published yet -- an empty result without an error still confirms access.

### Python (boto3)

```python
import boto3

s3 = boto3.client("s3", region_name="eu-west-2")
response = s3.list_objects_v2(Bucket="stevecrawshaw-bucket", MaxKeys=5)
for obj in response.get("Contents", []):
    print(obj["Key"])
```

**Expected:** File keys printed to the console.

### AWS CLI (optional)

If you have the AWS CLI installed:

```bash
aws s3 ls s3://stevecrawshaw-bucket/
```

**Expected:** A listing of objects in the bucket.

## Troubleshooting

### "Access Denied" when listing but individual file access works

The IAM policy likely grants `s3:GetObject` on `arn:aws:s3:::stevecrawshaw-bucket/*` but is missing `s3:ListBucket` on `arn:aws:s3:::stevecrawshaw-bucket` (note: bucket ARN without the `/*` suffix). Contact the data owner to update the policy.

### Region errors or 301 redirects

Verify that `region = eu-west-2` is set in `~/.aws/config`. In DuckDB, always specify the region explicitly with `REGION 'eu-west-2'` in the secret definition. Omitting the region causes DuckDB to default to `us-east-1`, which will fail.

### "No credentials" error

- Check the file paths are correct for your operating system.
- Ensure the profile is named `[default]`. The default profile is used automatically unless you specify otherwise.
- On Windows, confirm there is no file extension (e.g. `.txt`) accidentally appended by your text editor.

### Credentials file vs config file confusion

The two files use slightly different profile header syntax:

| File | Default profile | Named profile |
|------|----------------|---------------|
| `credentials` | `[default]` | `[profile-name]` |
| `config` | `[default]` | `[profile profile-name]` |

For this setup you only need the `[default]` profile, which uses `[default]` in both files.
