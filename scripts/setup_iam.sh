#!/usr/bin/env bash
# setup_iam.sh -- Create IAM resources for DuckLake analyst S3 read access
#
# Prerequisites:
#   - AWS CLI installed and configured with admin credentials
#   - Run from the project root directory (references iam/ relative path)
#
# Idempotency note:
#   This script is NOT idempotent. Re-running it will fail if resources
#   already exist (e.g. "EntityAlreadyExists" errors). This is expected
#   and not an error to handle -- it means the resources were already created.

set -euo pipefail

# Step 1: Retrieve the AWS account ID
echo "Retrieving AWS account ID..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "Account ID: ${ACCOUNT_ID}"

# Step 2: Create the customer-managed IAM policy from the JSON file
# The policy grants read-only S3 access to stevecrawshaw-bucket
echo "Creating IAM policy: ducklake-s3-reader..."
aws iam create-policy \
    --policy-name ducklake-s3-reader \
    --policy-document file://iam/ducklake-s3-reader-policy.json \
    --description "Read-only S3 access to stevecrawshaw-bucket for DuckLake analysts"

POLICY_ARN="arn:aws:iam::${ACCOUNT_ID}:policy/ducklake-s3-reader"
echo "Policy ARN: ${POLICY_ARN}"

# Step 3: Create the IAM group for DuckLake readers
echo "Creating IAM group: ducklake-readers..."
aws iam create-group --group-name ducklake-readers

# Step 4: Attach the policy to the group
echo "Attaching policy to group..."
aws iam attach-group-policy \
    --group-name ducklake-readers \
    --policy-arn "${POLICY_ARN}"

# Step 5: Create the analyst IAM user
echo "Creating IAM user: ducklake-analyst..."
aws iam create-user --user-name ducklake-analyst

# Step 6: Add the user to the readers group
echo "Adding ducklake-analyst to ducklake-readers group..."
aws iam add-user-to-group \
    --group-name ducklake-readers \
    --user-name ducklake-analyst

# Step 7: Generate an access key for the analyst user
# IMPORTANT: The secret access key is only shown ONCE in this output.
echo ""
echo "============================================="
echo "  GENERATING ACCESS KEY -- SAVE THIS OUTPUT"
echo "============================================="
echo ""
aws iam create-access-key --user-name ducklake-analyst

echo ""
echo "============================================="
echo "  ACTION REQUIRED"
echo "============================================="
echo "  1. Copy the AccessKeyId and SecretAccessKey from the output above."
echo "  2. Store both values in Keeper for analyst distribution."
echo "  3. The SecretAccessKey will NOT be shown again."
echo "============================================="
