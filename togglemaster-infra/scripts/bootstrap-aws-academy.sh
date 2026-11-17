#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
IMAGE_TAG="${IMAGE_TAG:-v4}"
NEW_RELIC_LICENSE_KEY="${NEW_RELIC_LICENSE_KEY:-REPLACE_WITH_NEW_RELIC_LICENSE_KEY}"
GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-admin}"
PAGERDUTY_INTEGRATION_KEY="${PAGERDUTY_INTEGRATION_KEY:-REPLACE_WITH_PAGERDUTY_INTEGRATION_KEY}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-https://discord.com/api/webhooks/REPLACE_WITH_WEBHOOK_ID/REPLACE_WITH_TOKEN}"
GITHUB_DISPATCH_TOKEN="${GITHUB_DISPATCH_TOKEN:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd "$INFRA_DIR/.." && pwd)"
TERRAFORM_DIR="$INFRA_DIR/terraform"
GITOPS_DIR="$WORKSPACE_ROOT/togglemaster-gitops"

echo "============================================================"
echo " PASSO 1: Validando Credenciais do AWS Academy Learner Lab"
echo "============================================================"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
CALLER_ARN=$(aws sts get-caller-identity --query Arn --output text)
echo "Conectado na conta AWS Academy: $ACCOUNT_ID ($CALLER_ARN)"

TF_BUCKET="tc4-togglemaster-tfstate-${ACCOUNT_ID}"
if ! aws s3api head-bucket --bucket "$TF_BUCKET" 2>/dev/null; then
  echo "Criando bucket S3 para Terraform state: s3://${TF_BUCKET}"
  aws s3 mb "s3://${TF_BUCKET}" --region "$REGION"
fi

cat > "$TERRAFORM_DIR/backend.tf" <<EOF
terraform {
  backend "s3" {
    bucket = "${TF_BUCKET}"
    key    = "fase-4/terraform.tfstate"
    region = "${REGION}"

    use_lockfile = true
  }
}
EOF

echo "============================================================"
echo " PASSO 2: Provisionando Infraestrutura via Terraform (LabRole)"
echo "============================================================"
pushd "$TERRAFORM_DIR" >/dev/null
terraform init -reconfigure -upgrade
terraform apply -auto-approve -var="use_aws_academy=true"

AUTH_DB_HOST=$(terraform output -raw auth_db_endpoint)
FLAG_DB_HOST=$(terraform output -raw flag_db_endpoint)
TARGETING_DB_HOST=$(terraform output -raw targeting_db_endpoint)
REDIS_HOST=$(terraform output -raw redis_endpoint)
SQS_URL=$(terraform output -raw analytics_queue_url)
EKS_CLUSTER_NAME=$(terraform output -raw eks_cluster_name)
popd >/dev/null

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

echo "============================================================"
echo " PASSO 3: Build & Push das Imagens Docker para o ECR ($IMAGE_TAG)"
echo "============================================================"
aws ecr get-login-password --region "$REGION" | docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker build -f "$INFRA_DIR/db-init/Dockerfile" -t "${ECR_REGISTRY}/togglemaster-db-init:${IMAGE_TAG}" "$WORKSPACE_ROOT"
docker push "${ECR_REGISTRY}/togglemaster-db-init:${IMAGE_TAG}"

for svc in auth flag targeting evaluation analytics; do
  docker build -t "${ECR_REGISTRY}/togglemaster-${svc}:${IMAGE_TAG}" "$WORKSPACE_ROOT/togglemaster-${svc}"
  docker push "${ECR_REGISTRY}/togglemaster-${svc}:${IMAGE_TAG}"
done

echo "============================================================"
echo " PASSO 4: Atualizando Manifestos K8s/GitOps"
echo "============================================================"
python3 - <<PY
import pathlib, re

ecr_registry = "${ECR_REGISTRY}"
image_tag = "${IMAGE_TAG}"
redis_host = "${REDIS_HOST}"
sqs_url = "${SQS_URL}"

files = list(pathlib.Path("${GITOPS_DIR}/apps/togglemaster").glob("*.yaml")) + [
    pathlib.Path("${INFRA_DIR}/jobs/db-init.yaml")
]
for yaml_file in files:
    text = yaml_file.read_text(encoding="utf-8")
    text = re.sub(
        r"\d{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/(togglemaster-[a-z-]+):[^\s\"]+",
        f"{ecr_registry}/\\1:{image_tag}",
        text,
    )
    text = re.sub(r"redis://[^\s\"]+:6379", f"redis://{redis_host}:6379", text)
    text = re.sub(
        r"https://sqs\.[a-z0-9-]+\.amazonaws\.com/\d{12}/togglemaster-analytics",
        sqs_url,
        text,
    )
    yaml_file.write_text(text, encoding="utf-8")
PY

echo "============================================================"
echo " PASSO 5: Configurando kubectl, Secrets, db-init e Microsservicos"
echo "============================================================"
aws eks update-kubeconfig --region "$REGION" --name "$EKS_CLUSTER_NAME"

kubectl apply -f "$GITOPS_DIR/apps/togglemaster/namespace.yaml"
kubectl apply -f "$GITOPS_DIR/apps/togglemaster/service-accounts.yaml"

kubectl create secret generic togglemaster-app-secrets -n togglemaster \
  --from-literal=AUTH_DATABASE_URL="postgres://postgres:ToggleMasterAuth2026@${AUTH_DB_HOST}:5432/authdb?sslmode=require" \
  --from-literal=FLAG_DATABASE_URL="postgres://postgres:ToggleMasterFlag2026@${FLAG_DB_HOST}:5432/flagdb?sslmode=require" \
  --from-literal=TARGETING_DATABASE_URL="postgres://postgres:ToggleMasterTarget2026@${TARGETING_DB_HOST}:5432/targetingdb?sslmode=require" \
  --from-literal=MASTER_KEY="tm-master-key-2026" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic evaluation-service-secret -n togglemaster \
  --from-literal=SERVICE_API_KEY="tm_key_placeholder_bootstrap" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl delete job db-init -n togglemaster --ignore-not-found=true
kubectl apply -f "$INFRA_DIR/jobs/db-init.yaml"
kubectl wait --for=condition=complete job/db-init -n togglemaster --timeout=180s

kubectl apply -f "$GITOPS_DIR/apps/togglemaster/"

echo "============================================================"
echo " PASSO 6: Instalando ArgoCD e Stack de Observabilidade (Fase 4)"
echo "============================================================"
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic newrelic-license -n observability \
  --from-literal=license-key="$NEW_RELIC_LICENSE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-admin -n observability \
  --from-literal=admin-user="admin" \
  --from-literal=admin-password="$GRAFANA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic grafana-alerting-secrets -n observability \
  --from-literal=PAGERDUTY_INTEGRATION_KEY="$PAGERDUTY_INTEGRATION_KEY" \
  --from-literal=DISCORD_WEBHOOK_URL="$DISCORD_WEBHOOK_URL" \
  --from-literal=GITHUB_DISPATCH_TOKEN="$GITHUB_DISPATCH_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f "$GITOPS_DIR/apps/observability/"

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -
if command -v helm >/dev/null 2>&1; then
  helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true
  helm upgrade --install argocd argo/argo-cd -n argocd -f "$GITOPS_DIR/argocd/values.yaml" --wait --timeout 5m
else
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=240s
fi

kubectl apply -f "$GITOPS_DIR/argocd/applications/togglemaster.yaml"
kubectl apply -f "$GITOPS_DIR/argocd/applications/observability-dashboards.yaml"
kubectl apply -f "$GITOPS_DIR/argocd/applications/observability-kube-prometheus-stack.yaml"
kubectl apply -f "$GITOPS_DIR/argocd/applications/observability-loki.yaml"
kubectl apply -f "$GITOPS_DIR/argocd/applications/observability-otel-collector.yaml"

echo "Deploy completo finalizado com sucesso!"
