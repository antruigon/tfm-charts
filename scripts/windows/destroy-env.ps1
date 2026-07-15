#Requires -Version 5.1
<#
  Apagar el entorno TFM sin dejar ALB/security groups huérfanos que bloqueen la VPC.
  1. Borrar Ingress (ALB) mientras el clúster sigue vivo → el AWS LB Controller limpia el ALB.
  2. Esperar a que desaparezcan ALB y SG k8s-* de la VPC.
  3. Ejecutar terraform destroy (opcional con -SkipTerraform).
#>
param(
    [string]$ClusterName = "tfm-dev",
    [string]$AwsRegion = "eu-north-1",
    [int]$WaitTimeoutSeconds = 300,
    [switch]$SkipTerraform
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$TfDir = Join-Path $Root "..\tfm-terraform\aws\dev"

function Get-TerraformOutput {
    param([string]$Name)
    Push-Location $TfDir
    try {
        return (terraform output -raw $Name 2>$null)
    } finally {
        Pop-Location
    }
}

function Test-ClusterReachable {
    kubectl cluster-info 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

function Remove-KubernetesAlbIngresses {
    $ingresses = kubectl get ingress -A -o json 2>$null | ConvertFrom-Json
    if (-not $ingresses -or -not $ingresses.items) {
        Write-Host "  (sin Ingress en el clúster)" -ForegroundColor DarkGray
        return
    }

    foreach ($ing in $ingresses.items) {
        $class = $ing.spec.ingressClassName
        $ns = $ing.metadata.namespace
        $name = $ing.metadata.name
        if ($class -eq "alb") {
            Write-Host "  Borrando Ingress $ns/$name (clase alb)..." -ForegroundColor Yellow
            kubectl delete ingress $name -n $ns --wait=true --timeout=120s 2>$null
            if ($LASTEXITCODE -ne 0) {
                kubectl delete ingress $name -n $ns --ignore-not-found
            }
        }
    }
}

function Get-VpcAlbArns {
    param([string]$VpcId)
    $json = aws elbv2 describe-load-balancers --region $AwsRegion --output json 2>$null
    if (-not $json) { return @() }
    $lbs = ($json | ConvertFrom-Json).LoadBalancers
    if (-not $lbs) { return @() }
    return @($lbs | Where-Object { $_.VpcId -eq $VpcId } | ForEach-Object { $_.LoadBalancerArn })
}

function Get-VpcK8sSecurityGroups {
    param([string]$VpcId)
    $json = aws ec2 describe-security-groups `
        --filters "Name=vpc-id,Values=$VpcId" `
        --region $AwsRegion `
        --output json 2>$null
    if (-not $json) { return @() }
    $groups = ($json | ConvertFrom-Json).SecurityGroups
    if (-not $groups) { return @() }
    return @(
        $groups | Where-Object {
            $_.GroupName -like "k8s-*" -and $_.GroupName -ne "default"
        }
    )
}

function Wait-ForVpcAlbCleanup {
    param([string]$VpcId)

    $deadline = (Get-Date).AddSeconds($WaitTimeoutSeconds)
    $attempt = 0

    while ((Get-Date) -lt $deadline) {
        $attempt++
        $albs = Get-VpcAlbArns -VpcId $VpcId
        $sgs = Get-VpcK8sSecurityGroups -VpcId $VpcId

        if ($albs.Count -eq 0 -and $sgs.Count -eq 0) {
            Write-Host "  ALB y security groups k8s eliminados." -ForegroundColor Green
            return $true
        }

        Write-Host (
            "  Esperando limpieza AWS ($attempt) — ALB: $($albs.Count), SG k8s: $($sgs.Count)..."
        ) -ForegroundColor DarkGray
        Start-Sleep -Seconds 15
    }

    return $false
}

function Remove-OrphanK8sSecurityGroups {
    param([string]$VpcId)

    $sgs = Get-VpcK8sSecurityGroups -VpcId $VpcId
    foreach ($sg in $sgs) {
        Write-Host "  Intentando borrar SG huérfano $($sg.GroupName) ($($sg.GroupId))..." -ForegroundColor Yellow
        aws ec2 delete-security-group --group-id $sg.GroupId --region $AwsRegion 2>$null
    }
}

Write-Host "==> Pre-destroy: limpieza de recursos AWS creados por Kubernetes" -ForegroundColor Cyan

if (-not (Test-Path $TfDir)) {
    throw "No se encuentra $TfDir"
}

$VpcId = Get-TerraformOutput -Name "vpc_id"
if (-not $VpcId) {
    throw "No se pudo leer vpc_id de terraform output. ¿El entorno existe?"
}

Write-Host "  VPC: $VpcId | Región: $AwsRegion | Clúster: $ClusterName" -ForegroundColor DarkGray

aws eks update-kubeconfig --name $ClusterName --region $AwsRegion 2>$null | Out-Null

if (Test-ClusterReachable) {
    Write-Host "`n==> Borrando Ingress ALB (clúster activo → el controller limpia el ALB)..." -ForegroundColor Cyan
    Remove-KubernetesAlbIngresses
} else {
    Write-Host "`nAVISO: clúster no accesible. Solo se comprobará limpieza en AWS." -ForegroundColor Yellow
    Write-Host "  Si el destroy falló antes, borra SG huérfanos manualmente o espera a que AWS libere ENIs." -ForegroundColor Yellow
}

Write-Host "`n==> Esperando eliminación de ALB y security groups k8s (max ${WaitTimeoutSeconds}s)..." -ForegroundColor Cyan
$clean = Wait-ForVpcAlbCleanup -VpcId $VpcId

if (-not $clean) {
    Write-Host "`nAVISO: tiempo de espera agotado. Intentando borrar SG k8s huérfanos..." -ForegroundColor Yellow
    Remove-OrphanK8sSecurityGroups -VpcId $VpcId
    Start-Sleep -Seconds 30
    $clean = Wait-ForVpcAlbCleanup -VpcId $VpcId
}

if (-not $clean) {
    Write-Host @"

ERROR: Siguen recursos AWS en la VPC que bloquean terraform destroy.
Revisa en la consola EC2 (Load Balancers + Security Groups k8s-*) y vuelve a ejecutar:
  powershell -ExecutionPolicy Bypass -File .\scripts\windows\destroy-env.ps1
"@ -ForegroundColor Red
    exit 1
}

if ($SkipTerraform) {
    Write-Host "`n==> Limpieza completada (-SkipTerraform). Ejecuta terraform destroy cuando quieras." -ForegroundColor Green
    exit 0
}

Write-Host "`n==> Ejecutando terraform destroy..." -ForegroundColor Cyan
Push-Location $TfDir
try {
    terraform destroy
} finally {
    Pop-Location
}

Write-Host "`n==> Entorno apagado." -ForegroundColor Green
