#!/usr/bin/env bash
# Build y push de imagen mcp-server a ECR 
set -euo pipefail

AWS_REGION="${AWS_REGION:-eu-north-1}"
ACCOUNT_ID="${ACCOUNT_ID:-565083285597}"
TAG="${TAG:-latest}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
APP_DIR="$(cd "${ROOT}/../tfm-app/mcp-server" && pwd)"
ECR_URL="${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/mcp-server"

echo "==> Login ECR..."
aws ecr get-login-password --region "$AWS_REGION" | docker login --username AWS --password-stdin "${ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

echo "==> Build imagen..."
docker build -t "${ECR_URL}:${TAG}" "$APP_DIR"

echo "==> Push..."
docker push "${ECR_URL}:${TAG}"

echo ""
echo "Imagen publicada: ${ECR_URL}:${TAG}"
