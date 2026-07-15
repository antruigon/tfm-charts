#!/usr/bin/env bash
# Fase 4: Registrar Application de Argo CD para mcp-server.
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
CHART_DIR="${ROOT}/charts/mcp-server"
APP_MANIFEST="${ROOT}/apps/mcp-server.yaml"

if [[ "$LOCAL_HELM" == true ]]; then
  echo "==> Despliegue directo con Helm (sin GitOps remoto)..."
  helm upgrade --install mcp-server "$CHART_DIR" \
    -n apps --create-namespace \
    -f "${CHART_DIR}/values-dev.yaml" \
    --wait --timeout 5m
else
  echo "==> Aplicando Argo CD Application..."
  kubectl apply -f "$APP_MANIFEST"
  echo "Esperando sync de Argo CD..."
  sleep 15
  kubectl get application mcp-server -n argocd 2>/dev/null || true
fi

echo ""
echo "==> Pods en namespace apps:"
kubectl get pods -n apps
kubectl get svc -n apps
