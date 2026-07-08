#Requires -Version 5.1
<#
.SYNOPSIS
  Genera values-sealed.yaml con credenciales cifradas (kubeseal) para GitOps.
.NOTES
  Los tokens en texto plano NO se commitean; solo el resultado cifrado.
  Requiere: kubectl, kubeseal, clúster tfm-dev con Sealed Secrets (Fase 2).
#>
param(
    [string]$Namespace = "apps",
    [string]$SecretName = "ia-chatbot-secrets"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command kubeseal -ErrorAction SilentlyContinue)) {
    throw "kubeseal no encontrado. Instálalo con 'choco install kubeseal' o descarga el binario desde https://github.com/bitnami-labs/sealed-secrets/releases"
}

$BotToken = $env:SLACK_BOT_TOKEN
$AppToken = $env:SLACK_APP_TOKEN
$GroqKey = $env:GROQ_API_KEY

if (-not $BotToken) { $BotToken = Read-Host "SLACK_BOT_TOKEN (xoxb-...)" }
if (-not $AppToken) { $AppToken = Read-Host "SLACK_APP_TOKEN (xapp-...)" }
if (-not $GroqKey) { $GroqKey = Read-Host "GROQ_API_KEY (gsk_...)" }

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$Output = Join-Path $Root "charts\ia-chatbot\values-sealed.yaml"
$Plain = [System.IO.Path]::GetTempFileName()

try {
    kubectl create namespace $Namespace --dry-run=client -o yaml | kubectl apply -f -

    kubectl create secret generic $SecretName -n $Namespace `
        --from-literal=SLACK_BOT_TOKEN=$BotToken `
        --from-literal=SLACK_APP_TOKEN=$AppToken `
        --from-literal=GROQ_API_KEY=$GroqKey `
        --dry-run=client -o yaml | Set-Content -Path $Plain -Encoding utf8

    $sealedJson = Get-Content $Plain -Raw | kubeseal --format json `
        --controller-name sealed-secrets `
        --controller-namespace kube-system `
        --namespace $Namespace | ConvertFrom-Json
    $encrypted = $sealedJson.spec.encryptedData

    $lines = @(
        "# Credenciales del chatbot cifradas con kubeseal (seguros para commitear en Git).",
        "# Regenerar tras terraform destroy o rotación de tokens:",
        "#   Windows: .\scripts\windows\seal-ia-chatbot-secret.ps1",
        "#   Linux:   ./scripts/linux/seal-ia-chatbot-secret.sh",
        "# Requiere: clúster tfm-dev, Fase 2 (operador Sealed Secrets) y kubeseal instalado.",
        "sealedSecret:",
        "  enabled: true",
        "  encryptedData:"
    )

    foreach ($prop in $encrypted.PSObject.Properties) {
        $val = $prop.Value.ToString().Trim()
        $lines += "    $($prop.Name): `"$val`""
    }

    $content = ($lines -join "`n") + "`n"
    [System.IO.File]::WriteAllText($Output, $content, [System.Text.UTF8Encoding]::new($false))
} finally {
    Remove-Item $Plain -Force -ErrorAction SilentlyContinue
}

Write-Host "Generado: $Output" -ForegroundColor Green
Write-Host "Siguiente paso: git add charts/ia-chatbot/values-sealed.yaml && git commit && git push"
Write-Host "Argo CD materializará el Secret $SecretName en $Namespace."
