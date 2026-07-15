#Requires -Version 5.1
<#
  Fase 4: Registrar Application de Argo CD para mcp-server.
#>
param(
    [switch]$LocalHelm
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ChartDir = Join-Path $Root "charts\mcp-server"
$AppManifest = Join-Path $Root "apps\mcp-server.yaml"

if ($LocalHelm) {
    Write-Host "==> Despliegue directo con Helm (sin GitOps remoto)..." -ForegroundColor Cyan
    helm upgrade --install mcp-server $ChartDir `
        -n apps --create-namespace `
        -f (Join-Path $ChartDir "values-dev.yaml") `
        --wait --timeout 5m
} else {
    Write-Host "==> Aplicando Argo CD Application..." -ForegroundColor Cyan
    kubectl apply -f $AppManifest
    Write-Host "Esperando sync de Argo CD..."
    Start-Sleep -Seconds 15
    kubectl get application mcp-server -n argocd 2>$null
}

Write-Host "`n==> Pods en namespace apps:" -ForegroundColor Green
kubectl get pods -n apps
kubectl get svc -n apps
