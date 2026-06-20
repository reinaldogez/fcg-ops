#!/usr/bin/env bash
set -euo pipefail

# Aplica os manifestos do cluster em ordem de boot, esperando cada fase ficar pronta
# antes da próxima (namespace -> infra -> observabilidade -> serviços).
# Pré-requisito: cluster já criado (bootstrap-k3d.sh) e os Secrets reais preenchidos.
# Este script NÃO gera segredos nem chaves — só aplica o que está em disco.

NS="fcg"
K8S="k8s"
TIMEOUT="600s"   # generoso: o SQL Server demora a aceitar conexões.

# Secrets reais (não versionados). Sem eles a aplicação não sobe.
REQUIRED_SECRETS=(
  "$K8S/01-infra/sqlserver-identity/secret.yaml"
  "$K8S/01-infra/rabbitmq/secret.yaml"
  "$K8S/03-services/identity/secret.yaml"
  "$K8S/03-services/identity/secret-jwt.yaml"
)

# --- helpers -----------------------------------------------------------------

# Aborta cedo se algum Secret real estiver faltando, com instruções de como gerar.
check_required_secrets() {
  local missing=0 f
  for f in "${REQUIRED_SECRETS[@]}"; do
    if [[ ! -f "$f" ]]; then
      echo "erro: Secret real ausente: $f" >&2
      missing=1
    fi
  done
  [[ "$missing" -eq 0 ]] && return 0

  cat >&2 <<'EOF'

como resolver:
  1) preencha os valores reais no .env (cp .env.example .env, depois edite);
  2) materialize os Secrets com 'bash scripts/init-secrets.sh' (gera a chave RSA e os 4 secret.yaml).
  alternativa manual: copie cada secret.example.yaml para secret.yaml e preencha à mão.
EOF
  exit 1
}

# Aplica todos os .yaml de um diretório (recursivo), exceto os templates *.example.yaml.
apply_dir() {
  local dir="$1"
  find "$dir" -name '*.yaml' ! -name '*.example.yaml' -print0 \
    | xargs -0 -I{} kubectl apply -f {}
}

# Espera um pod (por label app=) ficar Ready.
wait_ready() {
  local app="$1"
  kubectl wait --for=condition=ready pod -l "app=$app" -n "$NS" --timeout="$TIMEOUT"
}

# --- fases de boot -----------------------------------------------------------

phase_namespace() {
  echo "==> namespace"
  kubectl apply -f "$K8S/00-namespace.yaml"
}

phase_infra() {
  echo "==> 01-infra"
  apply_dir "$K8S/01-infra"
  echo "    aguardando infra ficar Ready..."
  wait_ready "sqlserver-identity"
  wait_ready "rabbitmq"
}

phase_observability() {
  echo "==> 02-observability"
  apply_dir "$K8S/02-observability"
}

# A migration (Job) precisa concluir antes do Deployment subir.
phase_identity() {
  echo "==> 03-services/identity (Job de migration antes do Deployment)"
  local id="$K8S/03-services/identity"

  kubectl apply -f "$id/configmap.yaml"
  kubectl apply -f "$id/secret.yaml"
  kubectl apply -f "$id/secret-jwt.yaml"

  kubectl apply -f "$id/migrate-job.yaml"
  echo "    aguardando migration concluir..."
  kubectl wait --for=condition=complete job/identity-migrate -n "$NS" --timeout="$TIMEOUT"

  kubectl apply -f "$id/deployment.yaml"
  kubectl apply -f "$id/service.yaml"
}

# --- main --------------------------------------------------------------------

main() {
  check_required_secrets
  phase_namespace
  phase_infra
  phase_observability
  phase_identity

  echo ""
  echo "ok: manifestos aplicados. Acompanhe com: kubectl get pods -n $NS -w"
}

main "$@"
