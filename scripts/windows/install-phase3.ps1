#Requires -Version 5.1
<#
  Fase 3: Jenkins en EKS con JCasC (credenciales + Multibranch Pipeline tfm-app).
  Exportar credenciales antes de ejecutar:
#>
param(
    [string]$AwsRegion = "eu-north-1",
    [string]$GithubUser = "antruigon",
    [string]$GithubToken,
    [switch]$SkipScan,
    [switch]$SkipWebhook
)

$ErrorActionPreference = "Stop"
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent (Split-Path -Parent $ScriptDir)
$ValuesDir = Join-Path $Root "platform\values"
$JenkinsAdminPassword = "tfm-jenkins-dev"

if (-not $GithubUser) { $GithubUser = "antruigon" }
if (-not $GithubToken) { $GithubToken = $env:GITHUB_TOKEN }

Write-Host "==> Creando Secrets de Kubernetes para JCasC..." -ForegroundColor Cyan
$AccessKey = aws configure get aws_access_key_id
$SecretKey = aws configure get aws_secret_access_key

if (-not $AccessKey -or -not $SecretKey) {
    throw "No se encontraron credenciales AWS locales (aws configure). Necesarias para aws-ecr."
}
if (-not $GithubToken) {
    throw @"
GITHUB_TOKEN no definido. Exporta un PAT con permiso 'repo' antes de ejecutar:
  `$env:GITHUB_USER = "antruigon"
  `$env:GITHUB_TOKEN = "ghp_..."
"@
}

kubectl create namespace jenkins --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-aws-creds -n jenkins `
    --from-literal=access-key=$AccessKey `
    --from-literal=secret-key=$SecretKey `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic jenkins-github-creds -n jenkins `
    --from-literal=github-user=$GithubUser `
    --from-literal=github-token=$GithubToken `
    --dry-run=client -o yaml | kubectl apply -f -

Write-Host "==> Instalando Jenkins (JCasC: credenciales + job tfm-app)..." -ForegroundColor Cyan
helm repo add jenkins https://charts.jenkins.io 2>$null
helm repo update

helm upgrade --install jenkins jenkins/jenkins `
    -n jenkins `
    -f (Join-Path $ValuesDir "jenkins.yaml") `
    --wait --timeout 10m

if (-not $SkipWebhook) {
    Write-Host "`n==> Ingress ALB para /github-webhook..." -ForegroundColor Cyan
    kubectl apply -f (Join-Path $Root "platform\manifests\jenkins-webhook-ingress.yaml")

    Write-Host "`n==> Configurando webhook GitHub (ALB)..." -ForegroundColor Cyan
    $WebhookScript = Join-Path $ScriptDir "configure-jenkins-github-webhook.ps1"
    try {
        & $WebhookScript
    } catch {
        Write-Host "AVISO: webhook ALB no listo ($($_.Exception.Message)). Ejecuta luego:" -ForegroundColor Yellow
        Write-Host "  powershell -ExecutionPolicy Bypass -File .\scripts\windows\configure-jenkins-github-webhook.ps1" -ForegroundColor Yellow
    }
}

function Invoke-JenkinsMultibranchScan {
    param([string]$PodName)

    $auth = "admin:${JenkinsAdminPassword}"
    $scanUrl = "http://127.0.0.1:8080/job/tfm-app/descriptorByName/com.cloudbees.hudson.plugins.folder.computed.PeriodicFolderTrigger/check?delay=0sec"

    for ($i = 1; $i -le 12; $i++) {
        $ready = kubectl exec -n jenkins $PodName -c jenkins -- `
            curl -sf -o /dev/null -w "%{http_code}" -u $auth "http://127.0.0.1:8080/login" 2>$null
        if ($ready -eq "200") { break }
        Write-Host "  Esperando Jenkins ($i/12)..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }

    $crumbLine = kubectl exec -n jenkins $PodName -c jenkins -- `
        curl -sg -u $auth "http://127.0.0.1:8080/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,`":`",//crumb)" 2>$null

    if (-not $crumbLine) {
        throw "No se pudo obtener CSRF crumb de Jenkins"
    }

    $crumbField, $crumbValue = $crumbLine -split ":", 2
    kubectl exec -n jenkins $PodName -c jenkins -- `
        curl -sf -X POST -u $auth -H "${crumbField}:${crumbValue}" $scanUrl `
        2>$null | Out-Null

    if ($LASTEXITCODE -ne 0) {
        throw "Scan HTTP falló (exit $LASTEXITCODE)"
    }
}

if (-not $SkipScan) {
    Write-Host "`n==> Escaneando ramas del pipeline tfm-app..." -ForegroundColor Cyan
    $JenkinsPod = kubectl get pod -n jenkins -l "app.kubernetes.io/component=jenkins-controller" -o jsonpath="{.items[0].metadata.name}" 2>$null
    if ($JenkinsPod) {
        try {
            Invoke-JenkinsMultibranchScan -PodName $JenkinsPod
            Write-Host "Scan iniciado. La rama master aparecerá en unos segundos." -ForegroundColor Green
        } catch {
            Write-Host "AVISO: scan automático falló ($($_.Exception.Message)). En la UI: Scan Multibranch Pipeline Now." -ForegroundColor Yellow
        }
    }
}

Write-Host "`n==> Jenkins configurado automáticamente:" -ForegroundColor Green
Write-Host "  - Credencial aws-ecr"
Write-Host "  - Credencial github-tfm-charts"
Write-Host "  - Credencial github-tfm-app"
Write-Host "  - Multibranch Pipeline tfm-app (GitHub Branch Source + webhook)"
Write-Host "`n==> Jenkins UI (port-forward):" -ForegroundColor Green
Write-Host "  kubectl port-forward svc/jenkins -n jenkins 8081:8080"
Write-Host "  http://localhost:8081  (usuario: admin, password: tfm-jenkins-dev)"
Write-Host "`n==> Pods:" -ForegroundColor Green
kubectl get pods -n jenkins
