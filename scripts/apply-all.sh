#!/usr/bin/env bash
set -euo pipefail

# Aplica os manifestos do cluster em ordem de boot, esperando cada fase ficar pronta
# antes da próxima (namespace -> infra -> observabilidade -> serviços).
# Pré-requisito: cluster já criado (bootstrap-k3d.sh) e os Secrets reais preenchidos.
# Este script NÃO gera segredos nem chaves — só aplica o que está em disco.

NS="fcg"
K8S="k8s"
TIMEOUT="600s"   # generoso: o SQL Server demora a aceitar conexões.

# --- pré-condição: os Secrets reais precisam existir (não são versionados) ---
REQUIRED_SECRETS=(
  "$K8S/01-infra/sqlserver-identity/secret.yaml"
  "$K8S/01-infra/rabbitmq/secret.yaml"
  "$K8S/01-infra/redis/secret.yaml"
  "$K8S/01-infra/postgres-catalog/secret.yaml"
  "$K8S/01-infra/postgres-payments/secret.yaml"
  "$K8S/03-services/identity/secret.yaml"
  "$K8S/03-services/identity/secret-jwt.yaml"
  "$K8S/03-services/notifications/secret.yaml"
  "$K8S/03-services/catalog/secret.yaml"
  "$K8S/03-services/payments/secret.yaml"
)
missing=0
for f in "${REQUIRED_SECRETS[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "erro: Secret real ausente: $f" >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  echo "" >&2
  echo "como resolver:" >&2
  echo "  1) preencha os valores reais no .env (cp .env.example .env, depois edite);" >&2
  echo "  2) materialize os Secrets com 'bash scripts/init-secrets.sh' (gera a chave RSA e os secret.yaml)." >&2
  echo "  alternativa manual: copie cada secret.example.yaml para secret.yaml e preencha à mão." >&2
  exit 1
fi

# Aplica todos os .yaml de um diretório (recursivo), exceto os templates *.example.yaml.
apply_dir() {
  local dir="$1"
  find "$dir" -name '*.yaml' ! -name '*.example.yaml' -print0 \
    | xargs -0 -I{} kubectl apply -f {}
}

echo "==> namespace"
kubectl apply -f "$K8S/00-namespace.yaml"

echo "==> 01-infra"
apply_dir "$K8S/01-infra"
echo "    aguardando infra ficar Ready..."
kubectl wait --for=condition=ready pod -l app=sqlserver-identity -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=rabbitmq          -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=redis             -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=postgres-catalog  -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=postgres-payments -n "$NS" --timeout="$TIMEOUT"

echo "==> 02-observability"
apply_dir "$K8S/02-observability"

echo "==> 03-services/identity (Job de migration antes do Deployment)"
ID="$K8S/03-services/identity"
kubectl apply -f "$ID/configmap.yaml"
kubectl apply -f "$ID/secret.yaml"
kubectl apply -f "$ID/secret-jwt.yaml"
kubectl apply -f "$ID/migrate-job.yaml"
echo "    aguardando migration concluir..."
kubectl wait --for=condition=complete job/identity-migrate -n "$NS" --timeout="$TIMEOUT"
kubectl apply -f "$ID/deployment.yaml"
kubectl apply -f "$ID/service.yaml"

echo "==> 03-services/catalog (Job de migration+seed antes do Deployment)"
CT="$K8S/03-services/catalog"
kubectl apply -f "$CT/configmap.yaml"
kubectl apply -f "$CT/secret.yaml"
kubectl apply -f "$CT/migrate-job.yaml"
echo "    aguardando migration+seed concluir..."
kubectl wait --for=condition=complete job/catalog-migrate -n "$NS" --timeout="$TIMEOUT"
kubectl apply -f "$CT/deployment.yaml"
kubectl apply -f "$CT/service.yaml"

echo "==> 03-services/notifications"
NT="$K8S/03-services/notifications"
kubectl apply -f "$NT/configmap.yaml"
kubectl apply -f "$NT/secret.yaml"
kubectl apply -f "$NT/deployment.yaml"
kubectl apply -f "$NT/service.yaml"

echo "==> 03-services/payments (Job de migration antes do Deployment)"
PY="$K8S/03-services/payments"
kubectl apply -f "$PY/configmap.yaml"
kubectl apply -f "$PY/secret.yaml"
kubectl apply -f "$PY/migrate-job.yaml"
echo "    aguardando migration concluir..."
kubectl wait --for=condition=complete job/payments-migrate -n "$NS" --timeout="$TIMEOUT"
kubectl apply -f "$PY/deployment.yaml"
kubectl apply -f "$PY/service.yaml"

echo ""
echo "ok: manifestos aplicados. Acompanhe com: kubectl get pods -n $NS -w"
