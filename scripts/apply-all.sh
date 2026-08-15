#!/usr/bin/env bash
set -euo pipefail

# Aplica os manifestos do cluster em ordem de boot, esperando cada fase ficar pronta
# antes da próxima (namespace -> infra -> observabilidade -> serviços).
# Pré-requisito: cluster já criado (bootstrap-k3d.sh) e os Secrets reais preenchidos.
# Este script NÃO gera segredos nem chaves — só aplica o que está em disco.

NS="fcg"
K8S="k8s"
TIMEOUT="600s"   # generoso: o SQL Server demora a aceitar conexões.

# Perfil de ambiente: decide o que de 01-infra sobe e o que se espera ficar pronto.
# Validado antes de qualquer apply — perfil errado precisa falhar sem ter mexido no cluster.
FCG_PERFIL="${FCG_PERFIL:-k3d}"
case "$FCG_PERFIL" in
  k3d|ec2) ;;
  *)
    echo "erro: FCG_PERFIL inválido: '$FCG_PERFIL' (use 'k3d' ou 'ec2')" >&2
    exit 1
    ;;
esac

# --- pré-condição: os arquivos gerados precisam existir (não são versionados) ---
# Secrets (credenciais) e ConfigMaps de ambiente (valor que varia entre k3d e nuvem):
# ambos saem do init-secrets.sh a partir do .env.
REQUIRED_GENERATED=(
  "$K8S/01-infra/sqlserver-identity/secret.yaml"
  "$K8S/01-infra/rabbitmq/secret.yaml"
  "$K8S/01-infra/redis/secret.yaml"
  "$K8S/01-infra/postgres-catalog/secret.yaml"
  "$K8S/01-infra/postgres-payments/secret.yaml"
  "$K8S/03-services/identity/secret.yaml"
  "$K8S/03-services/identity/secret-jwt.yaml"
  "$K8S/03-services/catalog/secret.yaml"
  "$K8S/03-services/payments/secret.yaml"
  "$K8S/03-services/identity/configmap-env.yaml"
  "$K8S/03-services/catalog/configmap-env.yaml"
  "$K8S/03-services/payments/configmap-env.yaml"
)
missing=0
for f in "${REQUIRED_GENERATED[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "erro: arquivo gerado ausente: $f" >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  echo "" >&2
  echo "como resolver:" >&2
  echo "  1) preencha os valores reais no arquivo do perfil (cp .env.example .env.$FCG_PERFIL, depois edite);" >&2
  echo "  2) materialize os arquivos com 'bash scripts/init-secrets.sh' (gera a chave RSA, os secret.yaml e os configmap-env.yaml)." >&2
  echo "  alternativa manual: copie cada *.example.yaml para o nome sem '.example' e preencha à mão." >&2
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

echo "==> 01-infra (perfil: $FCG_PERFIL)"
# Bancos, Redis e observabilidade sobem igual nos dois perfis. O broker e o emulador do
# read model so existem no cluster local: na nuvem os dois sao servico gerenciado, e um
# broker local de pe ali seria um destino alternativo silencioso — configuracao errada
# conectaria nele e tudo pareceria funcionar, contra um broker vazio. A ausencia protege.
INFRA_DIRS=(sqlserver-identity postgres-catalog postgres-payments redis)
if [[ "$FCG_PERFIL" == "k3d" ]]; then
  INFRA_DIRS+=(rabbitmq dynamodb-local)
fi
for d in "${INFRA_DIRS[@]}"; do
  apply_dir "$K8S/01-infra/$d"
done

echo "    aguardando infra ficar Ready..."
kubectl wait --for=condition=ready pod -l app=sqlserver-identity -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=redis             -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=postgres-catalog  -n "$NS" --timeout="$TIMEOUT"
kubectl wait --for=condition=ready pod -l app=postgres-payments -n "$NS" --timeout="$TIMEOUT"
if [[ "$FCG_PERFIL" == "k3d" ]]; then
  kubectl wait --for=condition=ready pod -l app=rabbitmq          -n "$NS" --timeout="$TIMEOUT"
  # O emulador do read model precisa estar atendendo antes do catalog subir: a tabela e
  # criada no boot do servico, que tolera o endpoint fora do ar sem derrubar. Sem esta
  # espera o catalog sobe, nao cria a tabela, e o sintoma so aparece na primeira leitura
  # da biblioteca.
  kubectl wait --for=condition=ready pod -l app=dynamodb-local    -n "$NS" --timeout="$TIMEOUT"
fi

echo "==> 02-observability"
# Datasources e dashboards do Grafana nao sao YAML versionado: sao gerados a partir dos
# mesmos diretorios-fonte que o Compose monta, para nao manter duas copias divergentes.
kubectl create configmap grafana-datasources \
  --from-file=observability/grafana/provisioning/datasources/ \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl create configmap grafana-dashboards \
  --from-file=observability/grafana/provisioning/dashboards/ \
  -n "$NS" --dry-run=client -o yaml | kubectl apply -f -
# O apply_dir usa find | xargs, sem ordem garantida: o Deployment do Grafana consome as
# credenciais via envFrom, entao o Secret precisa existir antes. Aplica-se explicitamente
# aqui, como os servicos fazem com secret.yaml antes do deployment.yaml.
kubectl apply -f "$K8S/02-observability/grafana/secret.yaml"
apply_dir "$K8S/02-observability"

echo "==> 03-services/identity (Job de migration antes do Deployment)"
ID="$K8S/03-services/identity"
kubectl apply -f "$ID/configmap.yaml"
kubectl apply -f "$ID/configmap-env.yaml"
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
kubectl apply -f "$CT/configmap-env.yaml"
kubectl apply -f "$CT/secret.yaml"
kubectl apply -f "$CT/migrate-job.yaml"
echo "    aguardando migration+seed concluir..."
kubectl wait --for=condition=complete job/catalog-migrate -n "$NS" --timeout="$TIMEOUT"
kubectl apply -f "$CT/deployment.yaml"
kubectl apply -f "$CT/service.yaml"

echo "==> 03-services/payments (Job de migration antes do Deployment)"
PY="$K8S/03-services/payments"
kubectl apply -f "$PY/configmap.yaml"
kubectl apply -f "$PY/configmap-env.yaml"
kubectl apply -f "$PY/secret.yaml"
kubectl apply -f "$PY/migrate-job.yaml"
echo "    aguardando migration concluir..."
kubectl wait --for=condition=complete job/payments-migrate -n "$NS" --timeout="$TIMEOUT"
kubectl apply -f "$PY/deployment.yaml"
kubectl apply -f "$PY/service.yaml"

echo ""
echo "ok: manifestos aplicados. Acompanhe com: kubectl get pods -n $NS -w"
