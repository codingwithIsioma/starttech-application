#!/usr/bin/env bash
# Build the React frontend and deploy it to S3 behind CloudFront.
# Mirrors .github/workflows/frontend-ci-cd.yml:
#   npm ci -> npm audit -> npm run build -> aws s3 sync -> cloudfront invalidation
#
# Usage: ./scripts/deploy-frontend.sh
#
# Environment (all optional):
#   AWS_REGION                  default: us-east-1
#   FRONTEND_S3_BUCKET          default: starttech-frontend-bucket-<account-id>
#   CLOUDFRONT_DISTRIBUTION_ID  default: looked up via the S3-Frontend origin
#   VITE_API_BASE_URL           default: /api/v1 (relative path via unified CloudFront)
#   AUDIT_LEVEL                 npm audit level that fails the deploy (default: critical)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRONTEND_DIR="$ROOT_DIR/frontend"

export AWS_REGION="${AWS_REGION:-us-east-1}"
export VITE_API_BASE_URL="${VITE_API_BASE_URL:-/api/v1}"
AUDIT_LEVEL="${AUDIT_LEVEL:-critical}"

log() { printf '\n==> %s\n' "$*"; }

for cmd in npm aws; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required" >&2; exit 1; }
done

if [[ -z "${FRONTEND_S3_BUCKET:-}" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
  FRONTEND_S3_BUCKET="starttech-frontend-bucket-${ACCOUNT_ID}"
fi

if [[ -z "${CLOUDFRONT_DISTRIBUTION_ID:-}" ]]; then
  CLOUDFRONT_DISTRIBUTION_ID="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?Id=='S3-Frontend']].Id | [0]" \
    --output text)"
fi
if [[ -z "$CLOUDFRONT_DISTRIBUTION_ID" || "$CLOUDFRONT_DISTRIBUTION_ID" == "None" ]]; then
  echo "ERROR: no CloudFront distribution with origin 'S3-Frontend' found" >&2
  exit 1
fi

cd "$FRONTEND_DIR"

log "1/5 Installing Node.js packages (npm ci)"
npm ci

log "2/5 Security scan (npm audit, fails on '$AUDIT_LEVEL' or higher)"
npm audit --audit-level="$AUDIT_LEVEL"

log "3/5 Building static site (VITE_API_BASE_URL=$VITE_API_BASE_URL)"
npm run build
[[ -f dist/index.html ]] || { echo "ERROR: dist/index.html missing after build" >&2; exit 1; }

log "4/5 Syncing dist/ to s3://$FRONTEND_S3_BUCKET"
aws s3 sync dist/ "s3://$FRONTEND_S3_BUCKET" --delete

log "5/5 Invalidating CloudFront cache ($CLOUDFRONT_DISTRIBUTION_ID)"
aws cloudfront create-invalidation \
  --distribution-id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.{Id:Id,Status:Status}' --output table

CF_DOMAIN="$(aws cloudfront get-distribution --id "$CLOUDFRONT_DISTRIBUTION_ID" \
  --query 'Distribution.DomainName' --output text)"
log "Frontend deployed: https://$CF_DOMAIN"
