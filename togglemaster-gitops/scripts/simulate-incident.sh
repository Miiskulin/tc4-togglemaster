#!/usr/bin/env bash
set -euo pipefail

# ==============================================================================
# Script de Simulacao de Incidente e Prova Real de Self-Healing (Fase 4)
# ==============================================================================
# Uso:
#   ./scripts/simulate-incident.sh
# ==============================================================================

NAMESPACE="${NAMESPACE:-togglemaster}"
PORT="${PORT:-8004}"
REQUESTS="${REQUESTS:-45}"
DELAY_SECONDS="${DELAY_SECONDS:-2}"

echo "============================================================"
echo "1. Ativando falha (/debug/break -> HTTP 500) no evaluation-service"
echo "============================================================"
kubectl port-forward -n "$NAMESPACE" svc/evaluation-service "${PORT}:8004" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID >/dev/null 2>&1 || true' EXIT
sleep 3

curl -s -X POST "http://localhost:${PORT}/debug/break"
echo ""

echo "============================================================"
echo "2. Gerando trafego ($REQUESTS reqs) para superar 5% de erros 5xx"
echo "============================================================"
for i in $(seq 1 "$REQUESTS"); do
  STATUS=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:${PORT}/evaluate?user_id=user-123&flag_name=checkout-v2" || true)
  echo "Requisicao #$i -> HTTP $STATUS"
  sleep "$DELAY_SECONDS"
done

echo "============================================================"
echo "3. Acompanhe o alerta disparando no Grafana/PagerDuty/Discord"
echo "   e o pod reiniciando automaticamente via Self-Healing:"
echo "============================================================"
kubectl get pods -n "$NAMESPACE" -l "app=evaluation-service" -w
