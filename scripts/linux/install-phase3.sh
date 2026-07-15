#!/usr/bin/env bash
# Fase 3: Jenkins en EKS con JCasC (credenciales + Multibranch Pipeline tfm-app).
# Exportar credenciales antes de ejecutar:
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-north-1}"
GITHUB_USER="${GITHUB_USER:-antruigon}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
SKIP_SCAN=false
SKIP_WEBHOOK=false
JENKINS_ADMIN_PASSWORD="tfm-jenkins-dev"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --github-user) GITHUB_USER="$2"; shift 2 ;;
    --github-token) GITHUB_TOKEN="$2"; shift 2 ;;
    --skip-scan) SKIP_SCAN=true; shift ;;
    --skip-webhook) SKIP_WEBHOOK=true; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_DIR="${ROOT}/platform/values"

echo "==> Creando Secrets de Kubernetes para JCasC..."
ACCESS_KEY="$(aws configure get aws_access_key_id)"
SECRET_KEY="$(aws configure get aws_secret_access_key)"

if [[ -z "$ACCESS_KEY" || -z "$SECRET_KEY" ]]; then
  echo "No se encontraron credenciales AWS locales (aws configure). Necesarias para aws-ecr." >&2
  exit 1
fi
if [[ -z "$GITHUB_TOKEN" ]]; then
  cat >&2 <<'EOF'
GITHUB_TOKEN no definido. Exporta un PAT con permiso 'repo' antes de ejecutar:
  export GITHUB_USER="antruigon"
  export GITHUB_TOKEN="ghp_..."
EOF
  exit 1
fi

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-aws-creds -n jenkins \
  --from-literal=access-key="$ACCESS_KEY" \
  --from-literal=secret-key="$SECRET_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-github-creds -n jenkins \
  --from-literal=github-user="$GITHUB_USER" \
  --from-literal=github-token="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Instalando Jenkins (JCasC: credenciales + job tfm-app)..."
helm repo add jenkins https://charts.jenkins.io 2>/dev/null || true
helm repo update

helm upgrade --install jenkins jenkins/jenkins \
  -n jenkins \
  -f "${VALUES_DIR}/jenkins.yaml" \
  --wait --timeout 10m

if [[ "$SKIP_WEBHOOK" != true ]]; then
  echo ""
  echo "==> Ingress ALB para /github-webhook..."
  kubectl apply -f "${ROOT}/platform/manifests/jenkins-webhook-ingress.yaml"

  echo ""
  echo "==> Configurando webhook GitHub (ALB)..."
  if ! "${SCRIPT_DIR}/configure-jenkins-github-webhook.sh"; then
    echo "AVISO: webhook ALB no listo. Ejecuta luego:"
    echo "  ./scripts/linux/configure-jenkins-github-webhook.sh"
  fi
fi

invoke_jenkins_multibranch_scan() {
  local pod_name="$1"
  local auth="admin:${JENKINS_ADMIN_PASSWORD}"
  local scan_url="http://127.0.0.1:8080/job/tfm-app/descriptorByName/com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger/check?delay=0sec"
  local ready=""
  local i

  for i in $(seq 1 12); do
    ready="$(kubectl exec -n jenkins "$pod_name" -c jenkins -- \
      curl -sf -o /dev/null -w "%{http_code}" -u "$auth" "http://127.0.0.1:8080/login" 2>/dev/null || true)"
    if [[ "$ready" == "200" ]]; then
      break
    fi
    echo "  Esperando Jenkins (${i}/12)..."
    sleep 10
  done

  local crumb_line
  crumb_line="$(kubectl exec -n jenkins "$pod_name" -c jenkins -- \
    curl -sg -u "$auth" "http://127.0.0.1:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" 2>/dev/null || true)"

  if [[ -z "$crumb_line" ]]; then
    echo "No se pudo obtener CSRF crumb de Jenkins" >&2
    return 1
  fi

  local crumb_field="${crumb_line%%:*}"
  local crumb_value="${crumb_line#*:}"

  kubectl exec -n jenkins "$pod_name" -c jenkins -- \
    curl -sf -X POST -u "$auth" -H "${crumb_field}:${crumb_value}" "$scan_url" \
    >/dev/null 2>&1
}

if [[ "$SKIP_SCAN" != true ]]; then
  echo ""
  echo "==> Escaneando ramas del pipeline tfm-app..."
  JENKINS_POD="$(kubectl get pod -n jenkins -l "app.kubernetes.io/component=jenkins-controller" -o jsonpath="{.items[0].metadata.name}" 2>/dev/null || true)"
  if [[ -n "$JENKINS_POD" ]]; then
    if invoke_jenkins_multibranch_scan "$JENKINS_POD"; then
      echo "Scan iniciado. La rama master aparecerá en unos segundos."
    else
      echo "AVISO: scan automático falló. En la UI: Scan Multibranch Pipeline Now."
    fi
  fi
fi

echo ""
echo "==> Jenkins configurado automáticamente:"
echo "  - Credencial aws-ecr"
echo "  - Credencial github-tfm-charts"
echo "  - Credencial github-tfm-app"
echo "  - Multibranch Pipeline tfm-app (GitHub Branch Source + webhook)"
echo ""
echo "==> Jenkins UI (port-forward):"
echo "  kubectl port-forward svc/jenkins -n jenkins 8081:8080"
echo "  http://localhost:8081  (usuario: admin, password: tfm-jenkins-dev)"
echo ""
echo "==> Pods:"
kubectl get pods -n jenkins
