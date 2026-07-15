#!/usr/bin/env bash
set -euo pipefail

command -v jq >/dev/null 2>&1 || { echo "Se requiere jq instalado." >&2; exit 1; }

CLUSTER_NAME="${CLUSTER_NAME:-tfm-dev}"
AWS_REGION="${AWS_REGION:-eu-north-1}"
WAIT_TIMEOUT_SECONDS="${WAIT_TIMEOUT_SECONDS:-300}"
SKIP_TERRAFORM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) CLUSTER_NAME="$2"; shift 2 ;;
    --aws-region) AWS_REGION="$2"; shift 2 ;;
    --wait-timeout-seconds) WAIT_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --skip-terraform) SKIP_TERRAFORM=true; shift ;;
    *) echo "Opción desconocida: $1" >&2; exit 1 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
TF_DIR="${ROOT}/../tfm-terraform/aws/dev"

get_terraform_output() {
  local name="$1"
  (cd "$TF_DIR" && terraform output -raw "$name" 2>/dev/null) || true
}

test_cluster_reachable() {
  kubectl cluster-info >/dev/null 2>&1
}

remove_kubernetes_alb_ingresses() {
  local ingress_json
  ingress_json="$(kubectl get ingress -A -o json 2>/dev/null || echo '{}')"

  local count
  count="$(echo "$ingress_json" | jq '.items | length')"
  if [[ "$count" -eq 0 ]]; then
    echo "  (sin Ingress en el clúster)"
    return
  fi

  echo "$ingress_json" | jq -c '.items[] | select(.spec.ingressClassName == "alb") | {ns: .metadata.namespace, name: .metadata.name}' | \
  while IFS= read -r item; do
    local ns name
    ns="$(echo "$item" | jq -r '.ns')"
    name="$(echo "$item" | jq -r '.name')"
    echo "  Borrando Ingress ${ns}/${name} (clase alb)..."
    if ! kubectl delete ingress "$name" -n "$ns" --wait=true --timeout=120s 2>/dev/null; then
      kubectl delete ingress "$name" -n "$ns" --ignore-not-found 2>/dev/null || true
    fi
  done
}

get_vpc_alb_count() {
  local vpc_id="$1"
  aws elbv2 describe-load-balancers --region "$AWS_REGION" --output json 2>/dev/null | \
    jq --arg vpc "$vpc_id" '[.LoadBalancers[] | select(.VpcId == $vpc)] | length' || echo 0
}

get_vpc_k8s_sg_count() {
  local vpc_id="$1"
  aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | \
    jq '[.SecurityGroups[] | select(.GroupName | startswith("k8s-")) | select(.GroupName != "default")] | length' || echo 0
}

wait_for_vpc_alb_cleanup() {
  local vpc_id="$1"
  local deadline=$((SECONDS + WAIT_TIMEOUT_SECONDS))
  local attempt=0
  local alb_count sg_count

  while [[ $SECONDS -lt $deadline ]]; do
    attempt=$((attempt + 1))
    alb_count="$(get_vpc_alb_count "$vpc_id")"
    sg_count="$(get_vpc_k8s_sg_count "$vpc_id")"

    if [[ "$alb_count" -eq 0 && "$sg_count" -eq 0 ]]; then
      echo "  ALB y security groups k8s eliminados."
      return 0
    fi

    echo "  Esperando limpieza AWS (${attempt}) — ALB: ${alb_count}, SG k8s: ${sg_count}..."
    sleep 15
  done

  return 1
}

remove_orphan_k8s_security_groups() {
  local vpc_id="$1"
  aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=${vpc_id}" \
    --region "$AWS_REGION" \
    --output json 2>/dev/null | \
    jq -c --arg vpc "$vpc_id" \
      '.SecurityGroups[] | select(.GroupName | startswith("k8s-")) | select(.GroupName != "default") | {id: .GroupId, name: .GroupName}' | \
  while IFS= read -r sg; do
    local group_id group_name
    group_id="$(echo "$sg" | jq -r '.id')"
    group_name="$(echo "$sg" | jq -r '.name')"
    echo "  Intentando borrar SG huérfano ${group_name} (${group_id})..."
    aws ec2 delete-security-group --group-id "$group_id" --region "$AWS_REGION" 2>/dev/null || true
  done
}

echo "==> Pre-destroy: limpieza de recursos AWS creados por Kubernetes"

if [[ ! -d "$TF_DIR" ]]; then
  echo "No se encuentra ${TF_DIR}" >&2
  exit 1
fi

VPC_ID="$(get_terraform_output vpc_id)"
if [[ -z "$VPC_ID" ]]; then
  echo "No se pudo leer vpc_id de terraform output. ¿El entorno existe?" >&2
  exit 1
fi

echo "  VPC: ${VPC_ID} | Región: ${AWS_REGION} | Clúster: ${CLUSTER_NAME}"

aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null 2>&1 || true

if test_cluster_reachable; then
  echo ""
  echo "==> Borrando Ingress ALB (clúster activo → el controller limpia el ALB)..."
  remove_kubernetes_alb_ingresses
else
  echo ""
  echo "AVISO: clúster no accesible. Solo se comprobará limpieza en AWS."
  echo "  Si el destroy falló antes, borra SG huérfanos manualmente o espera a que AWS libere ENIs."
fi

echo ""
echo "==> Esperando eliminación de ALB y security groups k8s (max ${WAIT_TIMEOUT_SECONDS}s)..."
clean=false
if wait_for_vpc_alb_cleanup "$VPC_ID"; then
  clean=true
fi

if [[ "$clean" != true ]]; then
  echo ""
  echo "AVISO: tiempo de espera agotado. Intentando borrar SG k8s huérfanos..."
  remove_orphan_k8s_security_groups "$VPC_ID"
  sleep 30
  if wait_for_vpc_alb_cleanup "$VPC_ID"; then
    clean=true
  fi
fi

if [[ "$clean" != true ]]; then
  cat >&2 <<'EOF'

ERROR: Siguen recursos AWS en la VPC que bloquean terraform destroy.
Revisa en la consola EC2 (Load Balancers + Security Groups k8s-*) y vuelve a ejecutar:
  ./scripts/linux/destroy-env.sh
EOF
  exit 1
fi

if [[ "$SKIP_TERRAFORM" == true ]]; then
  echo ""
  echo "==> Limpieza completada (--skip-terraform). Ejecuta terraform destroy cuando quieras."
  exit 0
fi

echo ""
echo "==> Ejecutando terraform destroy..."
(cd "$TF_DIR" && terraform destroy)

echo ""
echo "==> Entorno apagado."
