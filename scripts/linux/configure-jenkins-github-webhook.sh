#!/usr/bin/env bash
# Ejecutar tras helm upgrade de Jenkins con secondaryingress habilitado.
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Se requiere jq instalado." >&2; exit 1; }

NAMESPACE="${NAMESPACE:-jenkins}"
INGRESS_NAME="${INGRESS_NAME:-jenkins-github-webhook}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-300}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --ingress-name) INGRESS_NAME="$2"; shift 2 ;;
    --timeout-seconds) TIMEOUT_SECONDS="$2"; shift 2 ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_FILE="${ROOT}/platform/values/jenkins.yaml"
INGRESS_MANIFEST="${ROOT}/platform/manifests/jenkins-webhook-ingress.yaml"

kubectl apply -f "$INGRESS_MANIFEST" >/dev/null

get_webhook_host() {
  local ing_json host
  ing_json="$(kubectl get ingress "$INGRESS_NAME" -n "$NAMESPACE" -o json 2>/dev/null || true)"

  if [[ -z "$ing_json" || "$ing_json" == "null" ]]; then
    ing_json="$(kubectl get ingress -n "$NAMESPACE" -o json | jq -c \
      '.items[] | select(.spec.rules[0].http.paths[]?.path | test("github-webhook"))' | head -n1)"
  fi

  if [[ -z "$ing_json" ]]; then
    return 1
  fi

  host="$(echo "$ing_json" | jq -r '.status.loadBalancer.ingress[0].hostname // empty')"
  if [[ -z "$host" ]]; then
    host="$(echo "$ing_json" | jq -r '.status.loadBalancer.ingress[0].ip // empty')"
  fi
  if [[ -z "$host" ]]; then
    host="$(echo "$ing_json" | jq -r '.spec.rules[0].host // empty')"
  fi

  if [[ -n "$host" ]]; then
    echo "$host"
  fi
}

echo "==> Esperando ALB del Ingress de webhook (max ${TIMEOUT_SECONDS}s)..."
deadline=$((SECONDS + TIMEOUT_SECONDS))
webhook_host=""

while [[ $SECONDS -lt $deadline ]]; do
  webhook_host="$(get_webhook_host || true)"
  if [[ -n "$webhook_host" ]]; then
    break
  fi
  sleep 10
  echo "  Esperando hostname del ALB..."
done

if [[ -z "$webhook_host" ]]; then
  kubectl get ingress -n "$NAMESPACE" 2>&1 || true
  echo "No se obtuvo hostname del ALB. Revisa el AWS Load Balancer Controller." >&2
  exit 1
fi

jenkins_url="http://${webhook_host}/"
webhook_url="${jenkins_url}github-webhook/"

echo "==> Actualizando jenkinsUrl: ${jenkins_url}"
helm upgrade jenkins jenkins/jenkins \
  -n "$NAMESPACE" \
  -f "$VALUES_FILE" \
  --set "controller.jenkinsUrl=${jenkins_url}" \
  --wait --timeout 10m

echo ""
echo "========================================"
echo " Webhook GitHub (configurar en el repo)"
echo "========================================"
echo "Repo:  https://github.com/antruigon/tfm-app"
echo "URL:   ${webhook_url}"
echo "Event: Just the push event"
echo "SSL:   desactivado (HTTP)"
echo ""
echo "GitHub -> Settings -> Webhooks -> Add webhook"
echo ""
echo "UI Jenkins (local): kubectl port-forward svc/jenkins -n jenkins 8081:8080"
echo "========================================"
echo ""
