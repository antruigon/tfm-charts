#Requires -Version 5.1
<#
  Build y push de imagen mcp-server a ECR (bootstrap antes de GitOps/Jenkins).
#>
param(
    [string]$AwsRegion = "eu-north-1",
    [string]$AccountId = "565083285597",
    [string]$Tag = "latest"
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$AppDir = Join-Path $Root "..\tfm-app\mcp-server"
$EcrUrl = "$AccountId.dkr.ecr.$AwsRegion.amazonaws.com/mcp-server"

Write-Host "==> Login ECR..." -ForegroundColor Cyan
aws ecr get-login-password --region $AwsRegion | docker login --username AWS --password-stdin "$AccountId.dkr.ecr.$AwsRegion.amazonaws.com"

Write-Host "==> Build imagen..." -ForegroundColor Cyan
docker build -t "${EcrUrl}:${Tag}" $AppDir

Write-Host "==> Push..." -ForegroundColor Cyan
docker push "${EcrUrl}:${Tag}"

Write-Host "`nImagen publicada: ${EcrUrl}:${Tag}" -ForegroundColor Green
