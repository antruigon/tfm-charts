# tfm-charts

Charts Helm y manifiestos GitOps (Argo CD) del TFM.

## Estructura

```text
platform/values/     # values Helm para componentes de plataforma (Fase 2)
apps/platform/       # Argo CD Applications (post-bootstrap)
scripts/windows/     # Scripts PowerShell (Windows)
scripts/linux/       # Scripts Bash (Linux/macOS)
```

## Fase 2 — Instalación en el clúster

Requisitos: EKS `tfm-dev` accesible con `kubectl`, Helm 3, y el rol IRSA del ALB controller (Terraform `aws/dev`).

**Nodo `t3.small`:** los values en `platform/values/` están ajustados al mínimo. El script escala CoreDNS a 1 réplica y el ALB controller a 1 réplica (límite ~11 pods por nodo en EKS).

```powershell
# 1. Aplicar IAM del ALB controller (tfm-terraform)
cd ../tfm-terraform/aws/dev
terraform apply -target=module.alb_controller_iam

# 2. Instalar componentes de plataforma
cd ../../tfm-charts
.\scripts\windows\install-phase2.ps1
```

En Linux/macOS:

```bash
chmod +x scripts/linux/*.sh
./scripts/linux/install-phase2.sh
```

Componentes instalados:

| Orden | Componente | Namespace |
|-------|------------|-----------|
| 1 | metrics-server | kube-system |
| 2 | Sealed Secrets | kube-system |
| 3 | AWS Load Balancer Controller | kube-system |
| 4 | Argo CD | argocd |

## Argo CD (acceso UI)

Con `server.insecure: true` (dev), el servidor escucha **HTTP** en el puerto 8080 del pod. No uses `https://` en el navegador.

```powershell
kubectl port-forward svc/argocd-server -n argocd 8080:80
```

Abre **http://localhost:8080** (no https). Usuario: `admin`. Contraseña:

```powershell
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | ForEach-Object { [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($_)) }
```

## Repos relacionados

| Repo | Uso |
|------|-----|
| [tfm-terraform](https://github.com/antruigon/tfm-terraform) | VPC, EKS, ECR, IAM IRSA |
| [tfm-app](https://github.com/antruigon/tfm-app) | Apps + Jenkinsfile |

## Fase 5 — ia-chatbot (Slack + LangChain)

Credenciales vía **Sealed Secrets** (GitOps): los tokens se cifran con `kubeseal` y se versionan en `charts/ia-chatbot/values-sealed.yaml`. **No** van en texto plano a Git.

```powershell
# 1. Tras Fase 2 (operador Sealed Secrets activo), generar values-sealed.yaml
$env:SLACK_BOT_TOKEN = "xoxb-..."
$env:SLACK_APP_TOKEN = "xapp-..."
$env:GROQ_API_KEY = "gsk_..."
.\scripts\windows\seal-ia-chatbot-secret.ps1
git add charts/ia-chatbot/values-sealed.yaml
git commit -m "chore: sealed secrets ia-chatbot"
git push origin master

# 2. Despliegue (Helm local o Argo CD)
.\scripts\windows\install-phase5.ps1 -LocalHelm
# o: kubectl apply -f apps/ia-chatbot.yaml
```

En Linux:

```bash
export SLACK_BOT_TOKEN="xoxb-..." SLACK_APP_TOKEN="xapp-..." GROQ_API_KEY="gsk_..."
./scripts/linux/seal-ia-chatbot-secret.sh
git add charts/ia-chatbot/values-sealed.yaml && git commit && git push
./scripts/linux/install-phase5.sh --local-helm
```

> **Tras `terraform destroy`:** el controlador genera una clave nueva. Re-ejecuta `seal-ia-chatbot-secret` y vuelve a commitear `values-sealed.yaml`.
Argo CD Applications usan `targetRevision: master`.

## Flujo CI/CD (GitOps)

```text
merge master (tfm-app) → Jenkins → test + push ECR :<commit-7chars>
                      → push tfm-charts (values-dev.yaml tag = commit)
                      → Argo CD sync → rollout en EKS
```

Los tags de imagen en `charts/*/values-dev.yaml` son **SHA de commit** (ej. `7f6c9c1`), nunca `latest`.

### Configurar Jenkins (automático con JCasC)

```powershell
$env:GITHUB_USER = "antruigon"
$env:GITHUB_TOKEN = "ghp_..."   # PAT con permiso repo
.\scripts\windows\install-phase3.ps1
```

En Linux:

```bash
export GITHUB_USER="antruigon" GITHUB_TOKEN="ghp_..."
./scripts/linux/install-phase3.sh
```

El script crea los Secrets K8s, instala Jenkins y aplica vía **JCasC**:
- Credenciales `aws-ecr`, `github-tfm-charts`, `github-tfm-app`
- Multibranch Pipeline `tfm-app` (solo rama `master`)
- Scan inicial de ramas

Requisitos: credenciales AWS en `aws configure` y `GITHUB_TOKEN` en el entorno.

**Trigger automático (webhook GitHub):** Jenkins expone solo `/github-webhook/` vía ALB público. Tras `install-phase3.ps1`, registra el webhook en GitHub con la URL que imprime el script (evento **push**). Cada merge a `master` dispara el pipeline al instante.

```powershell
# Si ya tenías Jenkins sin webhook:
helm upgrade jenkins jenkins/jenkins -n jenkins -f platform\values\jenkins.yaml --wait
powershell -ExecutionPolicy Bypass -File .\scripts\windows\configure-jenkins-github-webhook.ps1
```

El PAT (`GITHUB_TOKEN`) necesita scope **`repo`**; para que Jenkins cree el hook solo, añade **`admin:repo_hook`** (PAT clásico) o créalo manualmente en GitHub.

Conectar repo `tfm-charts` en Argo CD UI (si es privado) con el mismo PAT.
