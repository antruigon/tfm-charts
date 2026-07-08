#!/usr/bin/env bash
# Genera values-sealed.yaml con credenciales cifradas (kubeseal) para GitOps.
# Los tokens en texto plano NO se commitean; solo el resultado cifrado.
# Requiere: kubectl, kubeseal, clúster tfm-dev con Sealed Secrets (Fase 2).
set -euo pipefail

command -v kubeseal >/dev/null 2>&1 || {
  echo "kubeseal no encontrado." >&2
  echo "  Windows: choco install kubeseal" >&2
  echo "  Binario: https://github.com/bitnami-labs/sealed-secrets/releases (kubeseal-<ver>-<os>-amd64)" >&2
  exit 1
}

NAMESPACE="${NAMESPACE:-apps}"
SECRET_NAME="${SECRET_NAME:-ia-chatbot-secrets}"

BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
APP_TOKEN="${SLACK_APP_TOKEN:-}"
GROQ_KEY="${GROQ_API_KEY:-}"

if [[ -z "$BOT_TOKEN" ]]; then
  read -r -p "SLACK_BOT_TOKEN (xoxb-...): " BOT_TOKEN
fi
if [[ -z "$APP_TOKEN" ]]; then
  read -r -p "SLACK_APP_TOKEN (xapp-...): " APP_TOKEN
fi
if [[ -z "$GROQ_KEY" ]]; then
  read -r -p "GROQ_API_KEY (gsk_...): " GROQ_KEY
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT="${ROOT}/charts/ia-chatbot/values-sealed.yaml"
PLAIN="$(mktemp)"
trap 'rm -f "$PLAIN"' EXIT

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" -n "$NAMESPACE" \
  --from-literal=SLACK_BOT_TOKEN="$BOT_TOKEN" \
  --from-literal=SLACK_APP_TOKEN="$APP_TOKEN" \
  --from-literal=GROQ_API_KEY="$GROQ_KEY" \
  --dry-run=client -o yaml > "$PLAIN"

SEALED_JSON="$(kubeseal --format json \
  --controller-name sealed-secrets \
  --controller-namespace kube-system \
  --namespace "$NAMESPACE" < "$PLAIN")"

write_values_sealed_header() {
  cat > "$OUTPUT" <<'HEADER'
# Credenciales del chatbot cifradas con kubeseal (seguros para commitear en Git).
# Regenerar tras terraform destroy o rotación de tokens:
#   Windows: .\scripts\windows\seal-ia-chatbot-secret.ps1
#   Linux:   ./scripts/linux/seal-ia-chatbot-secret.sh
# Requiere: clúster tfm-dev, Fase 2 (operador Sealed Secrets) y kubeseal instalado.
sealedSecret:
  enabled: true
  encryptedData:
HEADER
}

append_encrypted_pairs() {
  local count=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    local key="${line%%:*}"
    local value="${line#*: }"
    value="${value%\"}"
    value="${value#\"}"
    value="${value//$'\r'/}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    printf '    %s: "%s"\n' "$key" "$value" >> "$OUTPUT"
    count=$((count + 1))
  done
  echo "$count"
}

write_values_sealed_header
KEY_COUNT=0

if command -v jq >/dev/null 2>&1; then
  KEY_COUNT="$(append_encrypted_pairs < <(echo "$SEALED_JSON" | jq -r '.spec.encryptedData | to_entries[] | "\(.key): \(.value)"'))"
elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' 2>/dev/null; then
  KEY_COUNT="$(append_encrypted_pairs < <(echo "$SEALED_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for k, v in data['spec']['encryptedData'].items():
    print(f'{k}: {v}')
"))"
else
  SEALED_YAML="$(mktemp)"
  trap 'rm -f "$PLAIN" "$SEALED_YAML"' EXIT
  kubeseal --format yaml \
    --controller-name sealed-secrets \
    --controller-namespace kube-system \
    --namespace "$NAMESPACE" < "$PLAIN" > "$SEALED_YAML"
  KEY_COUNT="$(append_encrypted_pairs < <(awk '/^  encryptedData:/{f=1;next} f && /^    [A-Z0-9_]+:/{print; next} f && /^  [a-z]/{f=0}' "$SEALED_YAML"))"
fi

if [[ "${KEY_COUNT:-0}" -lt 1 ]]; then
  echo "ERROR: values-sealed.yaml sin claves cifradas (Python/jq no disponibles)." >&2
  echo "  En Windows usa: .\\scripts\\windows\\seal-ia-chatbot-secret.ps1" >&2
  exit 1
fi

echo "Generado: ${OUTPUT} (${KEY_COUNT} claves cifradas)"
echo "Siguiente paso: git add charts/ia-chatbot/values-sealed.yaml && git commit && git push"
echo "Argo CD materializará el Secret ${SECRET_NAME} en ${NAMESPACE}."
