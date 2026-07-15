#Requires -Version 5.1
<#
  Build y push manual a ECR (bootstrap local; en CI usa tag = commit SHA).
.PARAMETER Tag
  Tag de imagen (usar los 7 primeros chars del commit, ej. 7f6c9c1).
#>
param(
    [string]$AwsRegion = "eu-north-1",
    [string]$AccountId = "565083285597",
    [Parameter(Mandatory = $true)]
    [string]$Tag
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$AppRoot = Join-Path $Root "..\tfm-app"
$Registry = "$AccountId.dkr.ecr.$AwsRegion.amazonaws.com"

aws ecr get-login-password --region $AwsRegion | docker login --username AWS --password-stdin $Registry

foreach ($svc in @("mcp-server", "ia-chatbot")) {
    $dir = Join-Path $AppRoot $svc
    $image = "${Registry}/${svc}:${Tag}"
    Write-Host "==> Build $svc..." -ForegroundColor Cyan
    docker build -t $image $dir
    Write-Host "==> Push $svc..." -ForegroundColor Cyan
    docker push $image
}

Write-Host "`nImágenes publicadas con tag: $Tag" -ForegroundColor Green
