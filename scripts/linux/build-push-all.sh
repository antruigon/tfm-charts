#!/usr/bin/env bash
# Build y push manual a ECR 
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-north-1}"
ACCOUNT_ID="${ACCOUNT_ID:-test-account-id}"

if [[ $# -lt 1 ]]; then
  echo "Uso: $0 <tag>" >&2
  echo "  tag: los 7 primeros chars del commit, ej. 7f6c9c1" >&2
  exit 1
fi

TAG="$1"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_ROOT="$(cd "${ROOT}/../tfm-app" && pwd)"
REGISTRY="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "$REGISTRY"

for svc in mcp-server ia-chatbot; do
  dir="${APP_ROOT}/${svc}"
  image="${REGISTRY}/${svc}:${TAG}"
  echo "==> Build ${svc}..."
  docker build -t "$image" "$dir"
  echo "==> Push ${svc}..."
  docker push "$image"
done

echo ""
echo "Imágenes publicadas con tag: ${TAG}"
