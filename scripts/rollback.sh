#!/usr/bin/env bash
# Roll the backend deployment back to a previous revision.
#
# Usage:
#   ./scripts/rollback.sh              # roll back to the previous revision
#   ./scripts/rollback.sh <revision>   # roll back to a specific revision
#   ./scripts/rollback.sh --list       # show rollout history and exit
#
# Environment (all optional):
#   AWS_REGION        default: us-east-1
#   EKS_CLUSTER_NAME  default: starttech-cluster

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-starttech-cluster}"
DEPLOYMENT="deployment/backend-api"

log() { printf '\n==> %s\n' "$*"; }
current_image() {
  kubectl get "$DEPLOYMENT" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

log "Rollout history"
kubectl rollout history "$DEPLOYMENT"

if [[ "${1:-}" == "--list" ]]; then
  exit 0
fi

BEFORE="$(current_image)"
echo "Current image: $BEFORE"

if [[ -n "${1:-}" ]]; then
  log "Rolling back to revision $1"
  kubectl rollout undo "$DEPLOYMENT" --to-revision="$1"
else
  log "Rolling back to previous revision"
  kubectl rollout undo "$DEPLOYMENT"
fi

log "Waiting for rollback to complete"
kubectl rollout status "$DEPLOYMENT" --timeout=180s

AFTER="$(current_image)"
log "Rolled back: $BEFORE -> $AFTER"

echo
echo "NOTE: k8s/deployment.yaml in git still references the newer image."
echo "      The next pipeline run will redeploy it unless you revert that commit."

if [[ -x "$ROOT_DIR/scripts/health-check.sh" ]]; then
  log "Running health check"
  "$ROOT_DIR/scripts/health-check.sh"
fi
