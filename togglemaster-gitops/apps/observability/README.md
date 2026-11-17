# Observabilidade, OpenTelemetry, Alertas e Self-Healing (Runbook Fase 4)

Esta pasta contém os recursos de observabilidade provisionados via GitOps (**ArgoCD**) na aplicação `observability-dashboards` ([observability-dashboards.yaml](../../argocd/applications/observability-dashboards.yaml)):

- **`dashboard-togglemaster.yaml`**: Dashboard customizado do Grafana (`ToggleMaster - Visao Geral`) com métricas de saúde do ecossistema, taxa de requisições (RPS), erros HTTP 5xx, latência p95 por microsserviço, uso de CPU/memória por pod e por nó, e painel de logs em tempo real do **Loki**.
- **`alerting-rules.yaml`**: Regra de alerta inteligente (`evaluation-taxa-erro-5xx`) que dispara quando a taxa de respostas HTTP 5xx do `evaluation-service` supera **5%** por `1m`, além da política de notificação (`grafana-alerting-policy`).
- **`alerting-contact-points.yaml`**: Contact points do Grafana Alerting para **PagerDuty** (Events API v2), **Discord** (ChatOps) e **Self-Healing** (Webhook in-cluster + GitHub Actions `repository_dispatch`).
- **`self-healing-webhook.yaml`**: Serviço in-cluster (`self-healing-webhook`) com RBAC nativo do Kubernetes (`ServiceAccount` + `Role` + `RoleBinding`) que executa automaticamente `kubectl rollout restart deployment/<servico> -n togglemaster` assim que o alerta entra em estado `Firing`.

---

## 1. Arquitetura de Telemetria (OpenTelemetry Collector)

O **OpenTelemetry Collector** ([observability-otel-collector.yaml](../../argocd/applications/observability-otel-collector.yaml)) roda como **DaemonSet** no namespace `observability`:

1. **Coleta (Receivers):**
   - `otlp` (`:4317` gRPC e `:4318` HTTP): recebe traces e métricas dos 5 microsserviços (`auth-service`, `flag-service`, `targeting-service`, `evaluation-service`, `analytics-service`) via `status.hostIP` sem salto de rede entre nós.
   - `file_log`: coleta automaticamente os logs de todos os contêineres em `/var/log/pods`.
   - `kubeletstats`: coleta métricas de uso de CPU e memória dos pods diretamente do kubelet.
2. **Processamento (Processors):**
   - `memory_limiter`, `k8s_attributes`, `resourcedetection`, `resource/reduzir_cardinalidade` e `batch`.
3. **Exportação (Exporters):**
   - **Prometheus** (`:8889`): expõe métricas OTLP convertidas para raspagem via `PodMonitor`.
   - **Loki** (`http://loki.observability.svc.cluster.local:3100/otlp`): recebe os logs enriquecidos com metadados do Kubernetes.
   - **New Relic APM** (`https://otlp.nr-data.net`): recebe traces distribuídos (incluindo propagação W3C `traceparent` via HTTP e atributos de mensagem SQS), métricas e logs para visualização do **Distributed Tracing** e **Service Map**.

---

## 2. Secrets Necessários no Namespace `observability`

Os segredos nunca são versionados no Git. Eles são criados automaticamente pelo script `togglemaster-infra/scripts/bootstrap-aws-academy.ps1` (ou `.sh`), ou manualmente via `kubectl`:

```bash
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -

# 1. License Key do New Relic (Ingest - License)
kubectl create secret generic newrelic-license -n observability \
  --from-literal=license-key="SUA_NEW_RELIC_LICENSE_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. Credenciais de admin do Grafana
kubectl create secret generic grafana-admin -n observability \
  --from-literal=admin-user="admin" \
  --from-literal=admin-password="admin" \
  --dry-run=client -o yaml | kubectl apply -f -

# 3. Chaves de integracao de Alertas e Self-Healing
kubectl create secret generic grafana-alerting-secrets -n observability \
  --from-literal=PAGERDUTY_INTEGRATION_KEY="SUA_PAGERDUTY_INTEGRATION_KEY" \
  --from-literal=DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/SEU_ID/SEU_TOKEN" \
  --from-literal=GITHUB_DISPATCH_TOKEN="SEU_GITHUB_PAT_OPCIONAL" \
  --dry-run=client -o yaml | kubectl apply -f -
```

---

## 3. Runbook: Diagnóstico e Remediação de Incidente (`evaluation-taxa-erro-5xx`)

### Sintoma
O alerta **`Taxa de erro 5xx alta no evaluation-service`** entrou em estado **Firing** (proporção de respostas HTTP 5xx > 5% nos últimos 5 minutos).

### Automação de Self-Healing (Ação Automática)
Assim que o alerta dispara no Grafana:
1. Um incidente crítico é aberto no **PagerDuty**.
2. Uma notificação detalhada é publicada no **Discord**.
3. O contact point `self-healing` aciona:
   - O serviço in-cluster **`self-healing-webhook`**, que executa um `PATCH` de `rollout restart` no `deployment/evaluation-service` via API do Kubernetes (funciona inclusive no AWS Academy Learner Lab sem depender de OIDC/IAM).
   - O workflow [**Self-Healing**](../../../.github/workflows/self-healing.yml) no GitHub Actions via `repository_dispatch`, que executa `kubectl rollout restart deployment/evaluation-service -n togglemaster` e valida `/health`.

### Como Simular o Incidente e Demonstrar a Autocura (Prova Real)

Execute o script automatizado a partir da pasta `togglemaster-gitops`:

```powershell
# No Windows (PowerShell):
./scripts/simulate-incident.ps1

# No Linux / macOS / WSL:
./scripts/simulate-incident.sh
```

Ou manualmente:
```bash
# 1. Expor o evaluation-service localmente
kubectl port-forward -n togglemaster svc/evaluation-service 8004:8004

# 2. Injetar falha em memoria (passa a retornar HTTP 500 em /evaluate)
curl -X POST http://localhost:8004/debug/break

# 3. Gerar requisicoes para elevar a taxa de erro 5xx acima de 5%
for i in $(seq 1 40); do
  curl -s -o /dev/null -w "%{http_code}\n" "http://localhost:8004/evaluate?user_id=user-42&flag_name=checkout-v2"
  sleep 2
done

# 4. Acompanhar o rollout restart automatico executado pelo Self-Healing
kubectl get pods -n togglemaster -l app=evaluation-service -w
```

### Remediação Manual (Caso Necessário)
Se precisar restaurar o serviço imediatamente sem aguardar o alerta:
```bash
# Opcao A: Reiniciar o deployment
kubectl rollout restart deployment/evaluation-service -n togglemaster

# Opcao B: Desativar o modo de falha em memoria
curl -X POST http://localhost:8004/debug/heal
```
