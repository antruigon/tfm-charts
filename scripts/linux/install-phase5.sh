#!/usr/bin/env bash
# Fase 5: despliega ia-chatbot (requiere secret + charts en GitHub master).
set -euo pipefail

LOCAL_HELM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --local-helm) LOCAL_HELM=true; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CHART_DIR="${ROOT}/charts/ia-chatbot"
APP_MANIFEST="${ROOT}/apps/ia-chatbot.yaml"

if [[ "$LOCAL_HELM" == true ]]; then
  echo "==> Despliegue directo con Helm..."
  helm upgrade --install ia-chatbot "$CHART_DIR" \
    -n apps --create-namespace \
    -f "${CHART_DIR}/values-dev.yaml" \
    --wait --timeout 8m
else
  echo "==> Aplicando Argo CD Application..."
  kubectl apply -f "$APP_MANIFEST"
  sleep 10
  kubectl get application ia-chatbot -n argocd 2>/dev/null || true
fi

echo ""
echo "==> Pods:"
kubectl get pods -n apps -l app.kubernetes.io/name=ia-chatbot
