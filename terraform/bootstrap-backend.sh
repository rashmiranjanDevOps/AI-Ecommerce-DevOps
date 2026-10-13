#!/usr/bin/env bash
# Create (once) the S3 bucket and DynamoDB table that hold Terraform state and its lock.
# Safe to run again. Usage: ./terraform/bootstrap-backend.sh [region]
set -euo pipefail
REGION="${1:-${AWS_REGION:-ap-south-1}}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="nexvion-tfstate-${ACCOUNT}"
TABLE="nexvion-tf-locks"

echo "Account: $ACCOUNT  Region: $REGION"
if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "Bucket $BUCKET already exists"
else
  if [ "$REGION" = "us-east-1" ]; then aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" >/dev/null
  else aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null; fi
  echo "Created bucket $BUCKET"
fi
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "Lock table $TABLE already exists"
else
  aws dynamodb create-table --table-name "$TABLE" --region "$REGION" \
    --attribute-definitions AttributeName=LockID,AttributeType=S --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
  echo "Created lock table $TABLE"
fi

# Put the real bucket name into the backend files.
for f in "$(dirname "$0")"/environments/*/backend.hcl; do
  sed -i "s#^bucket .*#bucket         = \"$BUCKET\"#" "$f"
done
echo
echo "Done. Next:  cd terraform && terraform init -backend-config=environments/dev/backend.hcl"
