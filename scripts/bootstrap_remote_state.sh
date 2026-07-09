#!/usr/bin/env bash
# One-time bootstrap of the Terraform remote-state bucket.
#
# Creates an S3 bucket (versioned, encrypted, public access blocked) and
# writes infra/backend.hcl pointing at it. Terraform >= 1.11 locks state via
# S3-native lockfiles, so no DynamoDB table is required.
#
# Usage: scripts/bootstrap_remote_state.sh [bucket-name]
#   Default bucket name: tfstate-<account-id>-<region>
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${1:-tfstate-${ACCOUNT_ID}-${REGION}}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

echo "[INFO] Remote state bucket: s3://${BUCKET} (${REGION})"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "[INFO] Bucket already exists; ensuring settings"
else
  if [ "$REGION" = "us-east-1" ]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=${REGION}"
  fi
  echo "[INFO] Bucket created"
fi

# Versioning: every state revision is recoverable
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

# Encryption at rest
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

# State can contain sensitive values — never public
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  'BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true'

cat > "${REPO_ROOT}/infra/backend.hcl" <<EOF
bucket       = "${BUCKET}"
key          = "k3s/dev/terraform.tfstate"
region       = "${REGION}"
encrypt      = true
use_lockfile = true
EOF

echo "[INFO] Wrote infra/backend.hcl"
echo "[INFO] Next: terraform -chdir=infra init -backend-config=backend.hcl"
