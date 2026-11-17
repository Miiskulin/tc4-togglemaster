param(
    [string]$Region = "us-east-1",
    [string]$ImageTag = "v4",
    [string]$NewRelicLicenseKey = $(if ($env:NEW_RELIC_LICENSE_KEY) { $env:NEW_RELIC_LICENSE_KEY } else { "REPLACE_WITH_NEW_RELIC_LICENSE_KEY" }),
    [string]$GrafanaAdminPassword = $(if ($env:GRAFANA_ADMIN_PASSWORD) { $env:GRAFANA_ADMIN_PASSWORD } else { "admin" }),
    [string]$PagerDutyKey = $(if ($env:PAGERDUTY_INTEGRATION_KEY) { $env:PAGERDUTY_INTEGRATION_KEY } else { "REPLACE_WITH_PAGERDUTY_INTEGRATION_KEY" }),
    [string]$DiscordWebhookUrl = $(if ($env:DISCORD_WEBHOOK_URL) { $env:DISCORD_WEBHOOK_URL } else { "https://discord.com/api/webhooks/REPLACE_WITH_WEBHOOK_ID/REPLACE_WITH_TOKEN" }),
    [string]$GithubDispatchToken = $(if ($env:GITHUB_DISPATCH_TOKEN) { $env:GITHUB_DISPATCH_TOKEN } else { "" }),
    [switch]$SkipTerraform,
    [switch]$SkipDocker
)

$ErrorActionPreference = "Continue"
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$WorkspaceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$InfraDir = Join-Path $WorkspaceRoot "togglemaster-infra"
$TerraformDir = Join-Path $InfraDir "terraform"
$GitopsDir = Join-Path $WorkspaceRoot "togglemaster-gitops"

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASSO 0: Verificando Pre-requisitos (AWS CLI, Terraform, Docker, kubectl)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

if (-not (Get-Command terraform -ErrorAction SilentlyContinue)) {
    $PossibleTfDirs = @(
        "$env:LOCALAPPDATA\Microsoft\WinGet\Links",
        "C:\ProgramData\chocolatey\bin",
        "C:\HashiCorp\Terraform"
    )
    $WingetTf = Get-ChildItem -Path "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Filter "terraform.exe" -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($WingetTf) {
        $PossibleTfDirs += $WingetTf.DirectoryName
    }
    foreach ($Dir in $PossibleTfDirs) {
        if ($Dir -and (Test-Path (Join-Path $Dir "terraform.exe"))) {
            $env:PATH = "$Dir;$env:PATH"
            Write-Host "Terraform localizado em: $Dir" -ForegroundColor Green
            break
        }
    }
}

foreach ($Tool in @("aws", "terraform", "kubectl", "docker")) {
    if (-not (Get-Command $Tool -ErrorAction SilentlyContinue)) {
        throw "Ferramenta '$Tool' nao encontrada no PATH."
    }
}

if (-not $SkipDocker) {
    docker info >$null 2>$null
    if ($LASTEXITCODE -ne 0) {
        $DockerDesktopExe = "C:\Program Files\Docker\Docker\Docker Desktop.exe"
        if (Test-Path $DockerDesktopExe) {
            Write-Host "Iniciando o Docker Desktop automaticamente..." -ForegroundColor Yellow
            Start-Process $DockerDesktopExe
            $DockerReady = $false
            for ($i = 0; $i -lt 30; $i++) {
                Start-Sleep -Seconds 3
                docker info >$null 2>$null
                if ($LASTEXITCODE -eq 0) {
                    $DockerReady = $true
                    break
                }
            }
            if (-not $DockerReady) {
                throw "O Docker Desktop ainda nao terminou de inicializar. Aguarde e tente novamente."
            }
        } else {
            throw "O daemon do Docker nao esta respondendo."
        }
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASSO 1: Validando Credenciais do AWS Academy Learner Lab" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$CallerRaw = aws sts get-caller-identity --output json
if ($LASTEXITCODE -ne 0 -or -not $CallerRaw) {
    throw "Credenciais AWS invalidas ou expiradas. Atualize ~/.aws/credentials com os dados do AWS Academy."
}
$CallerJson = $CallerRaw | ConvertFrom-Json
$AccountId = $CallerJson.Account
$CallerArn = $CallerJson.Arn
Write-Host "Conectado na conta AWS Academy: $AccountId ($CallerArn)" -ForegroundColor Green

$TfBucket = "tc4-togglemaster-tfstate-$AccountId"
Write-Host "Garantindo bucket S3 para o Terraform State: s3://$TfBucket" -ForegroundColor Yellow
$S3Check = aws s3 ls "s3://$TfBucket" 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    if ($S3Check -match "AccessDenied|service_control_policy") {
        throw "Acesso negado pela Service Control Policy (SCP) do AWS Academy. Verifique no painel do AWS Academy se o Lab parou (clique em Start Lab e atualize ~/.aws/credentials) ou se o Budget do laboratorio esgotou.`nDetalhes: $S3Check"
    }
    Write-Host "Criando bucket s3://$TfBucket ..." -ForegroundColor Yellow
    aws s3 mb "s3://$TfBucket" --region $Region
    if ($LASTEXITCODE -ne 0) {
        throw "Falha ao criar o bucket S3 $TfBucket"
    }
    Start-Sleep -Seconds 3
}

$BackendFile = Join-Path $TerraformDir "backend.tf"
$BackendContent = @"
terraform {
  backend "s3" {
    bucket = "$TfBucket"
    key    = "fase-4/terraform.tfstate"
    region = "$Region"

    use_lockfile = true
  }
}
"@
[System.IO.File]::WriteAllText($BackendFile, $BackendContent, $Utf8NoBom)

if (-not $SkipTerraform) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PASSO 2: Provisionando Infraestrutura via Terraform (LabRole)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    Push-Location $TerraformDir
    try {
        terraform init -reconfigure -upgrade
        if ($LASTEXITCODE -ne 0) { throw "Falha no terraform init" }

        terraform apply -auto-approve -var="use_aws_academy=true"
        if ($LASTEXITCODE -ne 0) { throw "Falha no terraform apply" }
    } finally {
        Pop-Location
    }
}

Push-Location $TerraformDir
try {
    $AuthDbHost = (terraform output -raw auth_db_endpoint).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $AuthDbHost) { throw "Nao foi possivel ler os outputs do Terraform." }
    $FlagDbHost = (terraform output -raw flag_db_endpoint).Trim()
    $TargetingDbHost = (terraform output -raw targeting_db_endpoint).Trim()
    $RedisHost = (terraform output -raw redis_endpoint).Trim()
    $SqsUrl = (terraform output -raw analytics_queue_url).Trim()
    $EksClusterName = (terraform output -raw eks_cluster_name).Trim()
} finally {
    Pop-Location
}

$EcrRegistry = "$AccountId.dkr.ecr.$Region.amazonaws.com"
Write-Host "Outputs capturados:" -ForegroundColor Green
Write-Host "  EKS Cluster:  $EksClusterName"
Write-Host "  ECR Registry: $EcrRegistry"
Write-Host "  Auth DB:      $AuthDbHost"
Write-Host "  Flag DB:      $FlagDbHost"
Write-Host "  Targeting DB: $TargetingDbHost"
Write-Host "  Redis:        $RedisHost"
Write-Host "  SQS URL:      $SqsUrl"

if (-not $SkipDocker) {
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host " PASSO 3: Build & Push das Imagens Docker para o ECR ($ImageTag)" -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan

    $EcrPassword = (aws ecr get-login-password --region $Region | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or -not $EcrPassword) { throw "Falha ao obter senha do ECR" }
    docker logout $EcrRegistry >$null 2>$null
    docker login -u AWS -p $EcrPassword $EcrRegistry
    if ($LASTEXITCODE -ne 0) { throw "Falha no docker login para o ECR." }

    # db-init usa a raiz do monorepo como contexto de build
    $DbInitImage = "${EcrRegistry}/togglemaster-db-init:${ImageTag}"
    $DbInitDockerfile = Join-Path $InfraDir "db-init\Dockerfile"
    Write-Host "Construindo e enviando $DbInitImage ..." -ForegroundColor Yellow
    docker build -f $DbInitDockerfile -t $DbInitImage $WorkspaceRoot
    if ($LASTEXITCODE -ne 0) { throw "Falha no docker build de togglemaster-db-init" }
    docker push $DbInitImage
    if ($LASTEXITCODE -ne 0) { throw "Falha no docker push de togglemaster-db-init" }

    $Services = @(
        @{ Name = "togglemaster-auth";       Path = (Join-Path $WorkspaceRoot "togglemaster-auth") },
        @{ Name = "togglemaster-flag";       Path = (Join-Path $WorkspaceRoot "togglemaster-flag") },
        @{ Name = "togglemaster-targeting";  Path = (Join-Path $WorkspaceRoot "togglemaster-targeting") },
        @{ Name = "togglemaster-evaluation"; Path = (Join-Path $WorkspaceRoot "togglemaster-evaluation") },
        @{ Name = "togglemaster-analytics";  Path = (Join-Path $WorkspaceRoot "togglemaster-analytics") }
    )

    foreach ($Svc in $Services) {
        $FullImage = "${EcrRegistry}/$($Svc.Name):${ImageTag}"
        Write-Host "Construindo e enviando $FullImage ..." -ForegroundColor Yellow
        docker build -t $FullImage $Svc.Path
        if ($LASTEXITCODE -ne 0) { throw "Falha no docker build de $($Svc.Name)" }
        docker push $FullImage
        if ($LASTEXITCODE -ne 0) { throw "Falha no docker push de $($Svc.Name)" }
    }
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASSO 4: Atualizando Manifestos K8s/GitOps com Account ID e Endpoints" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

$YamlFiles = @()
$YamlFiles += Get-ChildItem -Path (Join-Path $GitopsDir "apps\togglemaster") -Filter "*.yaml"
$YamlFiles += Get-Item -Path (Join-Path $InfraDir "jobs\db-init.yaml")

foreach ($File in $YamlFiles) {
    $Content = [System.IO.File]::ReadAllText($File.FullName, $Utf8NoBom)
    $Content = [regex]::Replace(
        $Content,
        "\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/(togglemaster-[a-z-]+):[^\s`"]+",
        "${EcrRegistry}/`$1:${ImageTag}"
    )
    $Content = [regex]::Replace(
        $Content,
        "redis://[^\s`"]+:6379",
        "redis://${RedisHost}:6379"
    )
    $Content = [regex]::Replace(
        $Content,
        "https://sqs\.[a-z0-9-]+\.amazonaws\.com/\d{12}/togglemaster-analytics",
        $SqsUrl
    )
    [System.IO.File]::WriteAllText($File.FullName, $Content, $Utf8NoBom)
}

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASSO 5: Configurando kubectl, Secrets, db-init e Microsservicos" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

aws eks update-kubeconfig --region $Region --name $EksClusterName
if ($LASTEXITCODE -ne 0) { throw "Falha ao configurar kubeconfig para o cluster $EksClusterName" }

kubectl apply -f (Join-Path $GitopsDir "apps\togglemaster\namespace.yaml")
kubectl apply -f (Join-Path $GitopsDir "apps\togglemaster\service-accounts.yaml")

$AuthDbUrl = "postgres://postgres:ToggleMasterAuth2026@${AuthDbHost}:5432/authdb?sslmode=require"
$FlagDbUrl = "postgres://postgres:ToggleMasterFlag2026@${FlagDbHost}:5432/flagdb?sslmode=require"
$TargetDbUrl = "postgres://postgres:ToggleMasterTarget2026@${TargetingDbHost}:5432/targetingdb?sslmode=require"

kubectl create secret generic togglemaster-app-secrets -n togglemaster `
    --from-literal=AUTH_DATABASE_URL="$AuthDbUrl" `
    --from-literal=FLAG_DATABASE_URL="$FlagDbUrl" `
    --from-literal=TARGETING_DATABASE_URL="$TargetDbUrl" `
    --from-literal=MASTER_KEY="tm-master-key-2026" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic evaluation-service-secret -n togglemaster `
    --from-literal=SERVICE_API_KEY="tm_key_placeholder_bootstrap" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl delete job db-init -n togglemaster --ignore-not-found=true
kubectl apply -f (Join-Path $InfraDir "jobs\db-init.yaml")
Write-Host "Aguardando Job db-init inicializar os bancos PostgreSQL..." -ForegroundColor Yellow
kubectl wait --for=condition=complete job/db-init -n togglemaster --timeout=180s

kubectl apply -f (Join-Path $GitopsDir "apps\togglemaster")

Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " PASSO 6: Instalando ArgoCD e Stack de Observabilidade (Fase 4)" -ForegroundColor Cyan
Write-Host "============================================================" -ForegroundColor Cyan

kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic newrelic-license -n observability `
    --from-literal=license-key="$NewRelicLicenseKey" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-admin -n observability `
    --from-literal=admin-user="admin" `
    --from-literal=admin-password="$GrafanaAdminPassword" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-alerting-secrets -n observability `
    --from-literal=PAGERDUTY_INTEGRATION_KEY="$PagerDutyKey" `
    --from-literal=DISCORD_WEBHOOK_URL="$DiscordWebhookUrl" `
    --from-literal=GITHUB_DISPATCH_TOKEN="$GithubDispatchToken" `
    --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f (Join-Path $GitopsDir "apps\observability")

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
if (Get-Command helm -ErrorAction SilentlyContinue) {
    helm repo add argo https://argoproj.github.io/argo-helm >$null 2>$null
    helm repo update >$null 2>$null
    helm upgrade --install argocd argo/argo-cd -n argocd -f (Join-Path $GitopsDir "argocd\values.yaml") --wait --timeout 5m
} else {
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
    kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=240s
}

kubectl apply -f (Join-Path $GitopsDir "argocd\applications\togglemaster.yaml")
kubectl apply -f (Join-Path $GitopsDir "argocd\applications\observability-dashboards.yaml")
kubectl apply -f (Join-Path $GitopsDir "argocd\applications\observability-kube-prometheus-stack.yaml")
kubectl apply -f (Join-Path $GitopsDir "argocd\applications\observability-loki.yaml")
kubectl apply -f (Join-Path $GitopsDir "argocd\applications\observability-otel-collector.yaml")

Write-Host "============================================================" -ForegroundColor Green
Write-Host " Infraestrutura, Microsservicos e Observabilidade no ar!" -ForegroundColor Green
Write-Host "============================================================" -ForegroundColor Green
kubectl get pods -n togglemaster
kubectl get pods -n observability
