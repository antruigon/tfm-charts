#Requires -Version 5.1
<#
  Fase 5: despliega ia-chatbot (requiere secret + charts en GitHub master).
#>
param(
    [switch]$LocalHelm
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ChartDir = Join-Path $Root "charts\ia-chatbot"
$AppManifest = Join-Path $Root "apps\ia-chatbot.yaml"

if ($LocalHelm) {
    Write-Host "==> Despliegue directo con Helm..." -ForegroundColor Cyan
    helm upgrade --install ia-chatbot $ChartDir `
        -n apps --create-namespace `
        -f (Join-Path $ChartDir "values-dev.yaml") `
        --wait --timeout 8m
} else {
    Write-Host "==> Aplicando Argo CD Application..." -ForegroundColor Cyan
    kubectl apply -f $AppManifest
    Start-Sleep -Seconds 10
    kubectl get application ia-chatbot -n argocd 2>$null
}

Write-Host "`n==> Pods:" -ForegroundColor Green
kubectl get pods -n apps -l app.kubernetes.io/name=ia-chatbot
