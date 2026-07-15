#!/usr/bin/env bash
# Fase 2: metrics-server, Sealed Secrets, AWS LB Controller, Argo CD.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-tfm-dev}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
ALB_ROLE_ARN="${ALB_ROLE_ARN:-}"
VPC_ID="${VPC_ID:-}"
SKIP_ALB_CONTROLLER=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --alb-role-arn) ALB_ROLE_ARN="$2"; shift 2 ;;
    --vpc-id) VPC_ID="$2"; shift 2 ;;
    --skip-alb-controller) SKIP_ALB_CONTROLLER=true; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
VALUES_DIR="${ROOT}/platform/values"

get_terraform_output() {
  local name="$1"
  local tf_dir="${ROOT}/../tfm-terraform/aws/dev"
  if [[ ! -d "$tf_dir" ]]; then
    echo "No se encuentra ${tf_dir}. Indica --alb-role-arn y --vpc-id manualmente." >&2
    exit 1
  fi
  (cd "$tf_dir" && terraform output -raw "$name" 2>/dev/null) || true
}

echo "==> Verificando clúster..."
kubectl cluster-info >/dev/null
kubectl get nodes

echo "==> CoreDNS a 1 réplica (ahorro de pods en dev)..."
kubectl scale deployment coredns -n kube-system --replicas=1 2>/dev/null || true

if [[ -z "$ALB_ROLE_ARN" ]]; then
  ALB_ROLE_ARN="$(get_terraform_output aws_load_balancer_controller_role_arn)"
fi
if [[ -z "$VPC_ID" ]]; then
  VPC_ID="$(get_terraform_output vpc_id)"
fi

echo "==> Añadiendo repos Helm..."
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update 2>/dev/null || true
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update 2>/dev/null || true
helm repo add eks https://aws.github.io/eks-charts --force-update 2>/dev/null || true
helm repo add argo https://argoproj.github.io/argo-helm --force-update 2>/dev/null || true
helm repo update

echo "==> 1/4 metrics-server..."
helm upgrade --install metrics-server metrics-server/metrics-server \
  -n kube-system \
  -f "${VALUES_DIR}/metrics-server.yaml" \
  --wait --timeout 5m

echo "==> 2/4 Sealed Secrets..."
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  -n kube-system \
  -f "${VALUES_DIR}/sealed-secrets.yaml" \
  --wait --timeout 5m

if [[ "$SKIP_ALB_CONTROLLER" != true ]]; then
  echo "==> 3/4 AWS Load Balancer Controller (IRSA: ${ALB_ROLE_ARN})..."
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    -n kube-system \
    -f "${VALUES_DIR}/aws-load-balancer-controller.yaml" \
    --set "clusterName=${CLUSTER_NAME}" \
    --set "region=${AWS_REGION}" \
    --set "vpcId=${VPC_ID}" \
    --set replicaCount=1 \
    --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=${ALB_ROLE_ARN}" \
    --wait --timeout 5m
else
  echo "==> 3/4 AWS LB Controller omitido (--skip-alb-controller)"
fi

echo "==> 4/4 Argo CD..."
helm upgrade --install argocd argo/argo-cd \
  -n argocd --create-namespace \
  -f "${VALUES_DIR}/argocd.yaml" \
  --wait --timeout 10m

echo ""
echo "==> Estado de pods de plataforma:"
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server 2>/dev/null || true
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets 2>/dev/null || true
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller 2>/dev/null || true
kubectl get pods -n argocd

echo ""
echo "==> Argo CD UI:"
echo "  kubectl port-forward svc/argocd-server -n argocd 8080:80"
echo "  http://localhost:8080  (usuario: admin; NO usar https en dev)"
echo "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo"
