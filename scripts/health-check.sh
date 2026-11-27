#!/usr/bin/env bash
# End-to-end health check for the StartTech deployment.
# Checks the backend in-cluster, through the ALB, and through the unified
# CloudFront distribution (S3 frontend, SPA routing, HTTPS redirect, /api/* proxy).
#
# Usage: ./scripts/health-check.sh
#
# Environment (all optional):
#   AWS_REGION        default: us-east-1
#   EKS_CLUSTER_NAME  default: starttech-cluster
#   CF_DOMAIN         default: looked up via the S3-Frontend origin (e.g. d1234.cloudfront.net)
#   API_HEALTH_PATH   default: /api/v1/health
#
# Exits non-zero if any check fails.

set -uo pipefail

export AWS_REGION="${AWS_REGION:-us-east-1}"
EKS_CLUSTER_NAME="${EKS_CLUSTER_NAME:-starttech-cluster}"
API_HEALTH_PATH="${API_HEALTH_PATH:-/api/v1/health}"
DEPLOYMENT="backend-api"

PASS=0
FAIL=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL + 1)); }
section() { printf '\n== %s\n' "$*"; }

aws eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

# ---------------------------------------------------------------- Kubernetes
section "Kubernetes"

if kubectl rollout status "deployment/$DEPLOYMENT" --timeout=60s >/dev/null 2>&1; then
  pass "deployment/$DEPLOYMENT rollout complete"
else
  fail "deployment/$DEPLOYMENT rollout not complete"
fi

DESIRED="$(kubectl get deploy "$DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
READY="$(kubectl get deploy "$DEPLOYMENT" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
if [[ -n "$DESIRED" && "${READY:-0}" == "$DESIRED" ]]; then
  pass "pods ready: ${READY}/${DESIRED}"
else
  fail "pods ready: ${READY:-0}/${DESIRED:-?}"
  kubectl get pods -l "app=$DEPLOYMENT" 2>/dev/null | sed 's/^/       /'
fi

POD_HEALTH="$(kubectl exec "deploy/$DEPLOYMENT" -- wget -qO- -T 5 localhost:8080/health 2>/dev/null)"
if echo "$POD_HEALTH" | grep -q '"database":"ok"'; then
  pass "MongoDB reachable from pod"
else
  fail "MongoDB not reachable from pod: ${POD_HEALTH:-no response}"
fi
if echo "$POD_HEALTH" | grep -q '"cache":"ok"'; then
  pass "Redis (ElastiCache) reachable from pod"
else
  fail "Redis not reachable from pod: ${POD_HEALTH:-no response}"
fi

LAST_LOG="$(kubectl logs "deploy/$DEPLOYMENT" --tail=20 2>/dev/null | grep '^{' | tail -1)"
if [[ -n "$LAST_LOG" ]]; then
  pass "structured JSON logs on stdout"
else
  fail "no JSON log lines found on stdout"
fi

# ----------------------------------------------------------------------- ALB
section "Application Load Balancer"

ALB="$(kubectl get ingress "$DEPLOYMENT" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null)"
if [[ -n "$ALB" ]]; then
  pass "ingress has ALB address: $ALB"
  ALB_CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "http://$ALB/health")"
  if [[ "$ALB_CODE" == "200" ]]; then
    pass "ALB -> backend /health returns 200"
  else
    fail "ALB -> backend /health returned $ALB_CODE"
  fi
else
  fail "ingress $DEPLOYMENT has no ALB address"
fi

# ---------------------------------------------------------------- CloudFront
section "CloudFront"

if [[ -z "${CF_DOMAIN:-}" ]]; then
  CF_DOMAIN="$(aws cloudfront list-distributions \
    --query "DistributionList.Items[?Origins.Items[?Id=='S3-Frontend']].DomainName | [0]" \
    --output text 2>/dev/null)"
fi
if [[ -z "$CF_DOMAIN" || "$CF_DOMAIN" == "None" ]]; then
  fail "no CloudFront distribution with origin 'S3-Frontend' found"
else
  CF="https://$CF_DOMAIN"
  echo "  using $CF"

  CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$CF/")"
  [[ "$CODE" == "200" ]] && pass "frontend / returns 200" || fail "frontend / returned $CODE"

  CODE="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$CF/todos")"
  [[ "$CODE" == "200" ]] && pass "SPA route /todos returns 200 (index.html rewrite)" \
                         || fail "SPA route /todos returned $CODE"

  LOCATION="$(curl -s -o /dev/null -m 10 -w '%{redirect_url}' "http://$CF_DOMAIN/")"
  [[ "$LOCATION" == https://* ]] && pass "HTTP redirects to HTTPS" \
                                 || fail "HTTP did not redirect to HTTPS"

  API_BODY="$(curl -s -m 10 "$CF$API_HEALTH_PATH")"
  if echo "$API_BODY" | grep -q '"database"'; then
    pass "API $API_HEALTH_PATH returns backend JSON via CloudFront"
  elif echo "$API_BODY" | grep -qi '<!doctype html'; then
    fail "API $API_HEALTH_PATH returned index.html (request not reaching backend routes)"
  else
    fail "API $API_HEALTH_PATH unexpected response: ${API_BODY:0:120}"
  fi
fi

# ------------------------------------------------------------------- Summary
printf '\n== Summary: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
