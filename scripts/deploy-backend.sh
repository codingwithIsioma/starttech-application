#!/usr/bin/env bash
# Test, build, scan, push and deploy the Go backend to EKS.
# Mirrors .github/workflows/backend-ci-cd.yml:
#   go test -> docker build (git SHA tag) -> Trivy scan -> push to ECR
#   -> update k8s/deployment.yaml image -> kubectl apply -f k8s/ -> rollout status
#
# Usage: ./scripts/deploy-backend.sh
#
# Environment (all optional):
#   AWS_REGION        default: us-east-1
#   ECR_REPOSITORY    default: starttech-backend-api
#   EKS_CLUSTER_NAME  default: starttech-cluster
#   IMAGE_TAG         default: current git commit SHA
#   TRIVY_VERSION     default: 0.76.2
#   SKIP_TESTS=1      skip go test
#   MONGO_URI, JWT_SECRET_KEY
#                     if both are set, the backend-api-secrets Secret is created/updated

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKEND_DIR="$ROOT_DIR/backend"
DEPLOYMENT_FILE="$ROOT_DIR/k8s/deployment.yaml"

export AWS_REGION="${AWS_REGION:-us-east-1}"
ECR_REPOSITORY="${ECR_REPOSITORY:-starttech-backend-api}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-starttech-cluster}"
IMAGE_TAG="${IMAGE_TAG:-$(git -C "$ROOT_DIR" rev-parse HEAD)}"
TRIVY_VERSION="${TRIVY_VERSION:-0.76.2}"

log() { printf '\n==> %s\n' "$*"; }

for cmd in go docker aws kubectl git; do
  command -v "$cmd" >/dev/null || { echo "ERROR: '$cmd' is required" >&2; exit 1; }
done

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
IMAGE="${REGISTRY}/${ECR_REPOSITORY}:${IMAGE_TAG}"

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
  log "1/7 Running Go tests"
  (cd "$BACKEND_DIR" && go test ./...)
else
  log "1/7 Skipping Go tests (SKIP_TESTS=1)"
fi

log "2/7 Building image $IMAGE"
# EKS nodes are t3.medium (x86_64); force amd64 so builds from Apple Silicon also work.
docker build --platform linux/amd64 -t "$IMAGE" "$BACKEND_DIR"

log "3/7 Vulnerability scan (Trivy $TRIVY_VERSION)"
# OS packages: block on fixable HIGH/CRITICAL
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  "aquasec/trivy:${TRIVY_VERSION}" image \
  --exit-code 1 --ignore-unfixed --pkg-types os --severity CRITICAL,HIGH "$IMAGE"
# Go libraries: report only (application code is third-party)
docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
  "aquasec/trivy:${TRIVY_VERSION}" image \
  --exit-code 0 --ignore-unfixed --pkg-types library --severity CRITICAL,HIGH "$IMAGE"

log "4/7 Pushing image to ECR"
aws ecr get-login-password | docker login --username AWS --password-stdin "$REGISTRY"
docker push "$IMAGE"

log "5/7 Updating $DEPLOYMENT_FILE with new image tag"
# -i.bak works with both GNU sed (Linux) and BSD sed (macOS)
sed -i.bak "s|image: .*${ECR_REPOSITORY}:.*|image: ${IMAGE}|" "$DEPLOYMENT_FILE"
rm -f "${DEPLOYMENT_FILE}.bak"
grep 'image:' "$DEPLOYMENT_FILE"

log "6/7 Deploying to EKS cluster $EKS_CLUSTER_NAME"
aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION"

if [[ -n "${MONGO_URI:-}" && -n "${JWT_SECRET_KEY:-}" ]]; then
  kubectl create secret generic backend-api-secrets \
    --from-literal=MONGO_URI="$MONGO_URI" \
    --from-literal=JWT_SECRET_KEY="$JWT_SECRET_KEY" \
    --dry-run=client -o yaml | kubectl apply -f -
elif ! kubectl get secret backend-api-secrets >/dev/null 2>&1; then
  echo "ERROR: Secret backend-api-secrets missing. Set MONGO_URI and JWT_SECRET_KEY" \
       "or run: kubectl apply -f k8s/config.yaml" >&2
  exit 1
fi

kubectl apply -f "$ROOT_DIR/k8s/"

log "7/7 Verifying rollout"
if ! kubectl rollout status deployment/backend-api --timeout=180s; then
  echo "Rollout failed. Recent pod logs:" >&2
  kubectl logs deployment/backend-api --tail=20 >&2 || true
  echo "To roll back: ./scripts/rollback.sh" >&2
  exit 1
fi

log "Backend deployed: $IMAGE"
