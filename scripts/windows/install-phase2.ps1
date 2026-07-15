#Requires -Version 5.1
<#
  Fase 2: metrics-server, Sealed Secrets, AWS LB Controller, Argo CD.
#>
param(
    [string]$ClusterName = "tfm-dev",
    [string]$AwsRegion = "eu-north-1",
    [string]$AlbRoleArn = "",
    [string]$VpcId = "",
    [switch]$SkipAlbController
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ValuesDir = Join-Path $Root "platform\values"

function Get-TerraformOutput {
    param([string]$Name)
    $TfDir = Join-Path $Root "..\tfm-terraform\aws\dev"
    if (-not (Test-Path $TfDir)) {
        throw "No se encuentra $TfDir. Indica -AlbRoleArn y -VpcId manualmente."
    }
    Push-Location $TfDir
    try {
        return (terraform output -raw $Name 2>$null)
    } finally {
        Pop-Location
    }
}

Write-Host "==> Verificando clúster..." -ForegroundColor Cyan
kubectl cluster-info | Out-Null
kubectl get nodes

# t3.small: límite ~11 pods/nodo — 1 réplica de CoreDNS en dev
Write-Host "==> CoreDNS a 1 réplica (ahorro de pods en dev)..." -ForegroundColor Cyan
kubectl scale deployment coredns -n kube-system --replicas=1 2>$null

if (-not $AlbRoleArn) {
    $AlbRoleArn = Get-TerraformOutput "aws_load_balancer_controller_role_arn"
}
if (-not $VpcId) {
    $VpcId = Get-TerraformOutput "vpc_id"
}

Write-Host "==> Añadiendo repos Helm..." -ForegroundColor Cyan
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ --force-update 2>$null
helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets --force-update 2>$null
helm repo add eks https://aws.github.io/eks-charts --force-update 2>$null
helm repo add argo https://argoproj.github.io/argo-helm --force-update 2>$null
helm repo update

Write-Host "==> 1/4 metrics-server..." -ForegroundColor Cyan
helm upgrade --install metrics-server metrics-server/metrics-server `
    -n kube-system `
    -f (Join-Path $ValuesDir "metrics-server.yaml") `
    --wait --timeout 5m

Write-Host "==> 2/4 Sealed Secrets..." -ForegroundColor Cyan
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets `
    -n kube-system `
    -f (Join-Path $ValuesDir "sealed-secrets.yaml") `
    --wait --timeout 5m

if (-not $SkipAlbController) {
    Write-Host "==> 3/4 AWS Load Balancer Controller (IRSA: $AlbRoleArn)..." -ForegroundColor Cyan
    helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller `
        -n kube-system `
        -f (Join-Path $ValuesDir "aws-load-balancer-controller.yaml") `
        --set clusterName=$ClusterName `
        --set region=$AwsRegion `
        --set vpcId=$VpcId `
        --set replicaCount=1 `
        --set "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$AlbRoleArn" `
        --wait --timeout 5m
} else {
    Write-Host "==> 3/4 AWS LB Controller omitido (-SkipAlbController)" -ForegroundColor Yellow
}

Write-Host "==> 4/4 Argo CD..." -ForegroundColor Cyan
helm upgrade --install argocd argo/argo-cd `
    -n argocd --create-namespace `
    -f (Join-Path $ValuesDir "argocd.yaml") `
    --wait --timeout 10m

Write-Host "`n==> Estado de pods de plataforma:" -ForegroundColor Green
kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server 2>$null
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets 2>$null
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller 2>$null
kubectl get pods -n argocd

Write-Host "`n==> Argo CD UI:" -ForegroundColor Green
Write-Host "  kubectl port-forward svc/argocd-server -n argocd 8080:80"
Write-Host "  http://localhost:8080  (usuario: admin; NO usar https en dev)"
Write-Host "  Password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | % { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String(`$_)) }"
