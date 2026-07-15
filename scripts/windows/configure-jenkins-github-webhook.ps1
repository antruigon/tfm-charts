#Requires -Version 5.1
<#
  Esperar el ALB del Ingress de webhook y configura jenkinsUrl para GitHub.
  Ejecutar tras helm upgrade de Jenkins con secondaryingress habilitado.
#>
param(
    [string]$Namespace = "jenkins",
    [string]$IngressName = "jenkins-github-webhook",
    [int]$TimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ValuesFile = Join-Path $Root "platform\values\jenkins.yaml"
$IngressManifest = Join-Path $Root "platform\manifests\jenkins-webhook-ingress.yaml"

kubectl apply -f $IngressManifest | Out-Null

function Get-WebhookHost {
    $ing = kubectl get ingress $IngressName -n $Namespace -o json 2>$null | ConvertFrom-Json
    if (-not $ing) {
        $items = kubectl get ingress -n $Namespace -o json | ConvertFrom-Json
        $ing = $items.items | Where-Object { $_.spec.rules[0].http.paths.path -like "*github-webhook*" } | Select-Object -First 1
    }
    if (-not $ing) { return $null }

    $albHost = $ing.status.loadBalancer.ingress[0].hostname
    if (-not $albHost) { $albHost = $ing.status.loadBalancer.ingress[0].ip }
    if (-not $albHost) { $albHost = $ing.spec.rules[0].host }
    return $albHost
}

Write-Host "==> Esperando ALB del Ingress de webhook (max ${TimeoutSeconds}s)..." -ForegroundColor Cyan
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$webhookHost = $null

while ((Get-Date) -lt $deadline) {
    $webhookHost = Get-WebhookHost
    if ($webhookHost) { break }
    Start-Sleep -Seconds 10
    Write-Host "  Esperando hostname del ALB..." -ForegroundColor DarkGray
}

if (-not $webhookHost) {
    kubectl get ingress -n $Namespace 2>&1
    throw "No se obtuvo hostname del ALB. Revisa el AWS Load Balancer Controller."
}

$jenkinsUrl = "http://${webhookHost}/"
$webhookUrl = "${jenkinsUrl}github-webhook/"

Write-Host "==> Actualizando jenkinsUrl: $jenkinsUrl" -ForegroundColor Cyan
helm upgrade jenkins jenkins/jenkins `
    -n $Namespace `
    -f $ValuesFile `
    --set "controller.jenkinsUrl=$jenkinsUrl" `
    --wait --timeout 10m

Write-Host "`n========================================" -ForegroundColor Green
Write-Host " Webhook GitHub (configurar en el repo)" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host "Repo:  https://github.com/antruigon/tfm-app"
Write-Host "URL:   $webhookUrl"
Write-Host "Event: Just the push event"
Write-Host "SSL:   desactivado (HTTP)"
Write-Host ""
Write-Host "GitHub -> Settings -> Webhooks -> Add webhook"
Write-Host ""
Write-Host "UI Jenkins (local): kubectl port-forward svc/jenkins -n jenkins 8081:8080"
Write-Host "========================================`n" -ForegroundColor Green
