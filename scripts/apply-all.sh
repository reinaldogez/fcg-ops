#!/usr/bin/env bash
set -euo pipefail

# Aplica os manifestos do cluster em ordem de boot, esperando cada fase ficar pronta
# antes da próxima (namespace -> infra -> observabilidade -> serviços).
# Pré-requisito: cluster já criado e os Secrets reais preenchidos (init-secrets.sh).
# Este script não gera segredos nem chaves — só aplica o que está em disco.
#
# Toda validação vem antes do primeiro apply, nesta ordem: perfil, fase, contexto do
# kubectl, arquivos gerados, busca do eks, imagens do eks. Qualquer uma que falhe encerra
# sem ter mexido no cluster.

NS="fcg"
K8S="k8s"
TIMEOUT="600s"   # generoso: o SQL Server demora a aceitar conexões.

# Perfil de ambiente: decide o que de 01-infra sobe e o que se espera ficar pronto.
FCG_PERFIL="${FCG_PERFIL:-k3d}"
case "$FCG_PERFIL" in
  k3d|eks) ;;
  ec2) echo "erro: o perfil ec2 foi substituido por eks" >&2; exit 1 ;;
  *)
    echo "erro: FCG_PERFIL inválido: '$FCG_PERFIL' (use 'k3d' ou 'eks')" >&2
    exit 1
    ;;
esac

# Fase: na nuvem a base (bancos e observabilidade) e os serviços sobem em momentos
# diferentes da sessão, e reaplicar a base só para trocar a imagem dos serviços é
# esperar o SQL Server de novo sem motivo.
FCG_FASE="${FCG_FASE:-tudo}"
case "$FCG_FASE" in
  tudo|base|servicos) ;;
  *)
    echo "erro: FCG_FASE inválida: '$FCG_FASE' (use 'tudo', 'base' ou 'servicos')" >&2
    exit 1
    ;;
esac
FASE_BASE=0
FASE_SERVICOS=0
[[ "$FCG_FASE" == "tudo" || "$FCG_FASE" == "base" ]] && FASE_BASE=1
[[ "$FCG_FASE" == "tudo" || "$FCG_FASE" == "servicos" ]] && FASE_SERVICOS=1

# Guarda de contexto: o mesmo laptop fala com o k3d e com o eks, e o perfil errado no
# cluster errado aplicaria manifestos de um ambiente no outro sem erro nenhum.
CONTEXTO_ATUAL="$(kubectl config current-context 2>/dev/null || true)"
case "$FCG_PERFIL" in
  k3d)
    CONTEXTO_ESPERADO="k3d-fcg"
    [[ "$CONTEXTO_ATUAL" == "k3d-fcg" ]] && CONTEXTO_OK=1 || CONTEXTO_OK=0
    ;;
  eks)
    CONTEXTO_ESPERADO="terminado em ':cluster/fcg-eks'"
    [[ "$CONTEXTO_ATUAL" == *":cluster/fcg-eks" ]] && CONTEXTO_OK=1 || CONTEXTO_OK=0
    ;;
esac
if [[ "$CONTEXTO_OK" -ne 1 ]]; then
  echo "erro: o contexto atual do kubectl não casa com o perfil '$FCG_PERFIL'." >&2
  echo "      atual:    '${CONTEXTO_ATUAL:-<nenhum>}'" >&2
  echo "      esperado: $CONTEXTO_ESPERADO" >&2
  exit 1
fi

# --- pré-condição: os arquivos gerados precisam existir (não são versionados) ---
# Secrets (credenciais) e ConfigMaps de ambiente (valor que varia entre k3d e nuvem):
# ambos saem do init-secrets.sh a partir do .env. Só se cobra o que a fase aplica.
REQUIRED_GENERATED=()
if [[ "$FASE_BASE" -eq 1 ]]; then
  REQUIRED_GENERATED+=(
    "$K8S/01-infra/sqlserver-identity/secret.yaml"
    "$K8S/01-infra/rabbitmq/secret.yaml"
    "$K8S/01-infra/redis/secret.yaml"
    "$K8S/01-infra/postgres-catalog/secret.yaml"
    "$K8S/01-infra/postgres-payments/secret.yaml"
    "$K8S/02-observability/grafana/secret.yaml"
  )
fi
if [[ "$FASE_SERVICOS" -eq 1 ]]; then
  REQUIRED_GENERATED+=(
    "$K8S/03-services/identity/secret.yaml"
    "$K8S/03-services/identity/secret-jwt.yaml"
    "$K8S/03-services/catalog/secret.yaml"
    "$K8S/03-services/payments/secret.yaml"
    "$K8S/03-services/identity/configmap-env.yaml"
    "$K8S/03-services/catalog/configmap-env.yaml"
    "$K8S/03-services/payments/configmap-env.yaml"
  )
fi
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

# Na nuvem, a fase de serviços exige a busca ligada no catalog-env. Sem a chave o catalog
# sobe saudável e a busca responde 503: o rollout não denuncia nada, e o defeito só aparece
# no uso. A barreira fica aqui, onde o erro ainda é barato. O perfil k3d não tem busca e
# não é afetado.
if [[ "$FCG_PERFIL" == "eks" && "$FASE_SERVICOS" -eq 1 ]] \
  && ! grep -qE "^[[:space:]]+OpenSearch__Endpoint: 'https://" "$K8S/03-services/catalog/configmap-env.yaml"; then
  echo "erro: o catalog-env do perfil eks não tem OpenSearch__Endpoint — a busca subiria desligada." >&2
  echo "" >&2
  echo "como resolver, depois de o apply do terraform/session terminar:" >&2
  echo "  FCG_PERFIL=eks bash scripts/busca-env.sh" >&2
  echo "  FCG_PERFIL=eks bash scripts/init-secrets.sh" >&2
  exit 1
fi

# No eks a imagem de serviço é a do ECR presa ao commit da main de cada repositório.
# Resolvê-la aqui, ainda na validação, faz imagem ausente falhar antes de qualquer apply.
# As quatro linhas são conferidas uma a uma antes de exportar: a saída de outro script
# nunca é executada como código.
if [[ "$FCG_PERFIL" == "eks" && "$FASE_SERVICOS" -eq 1 ]]; then
  if ! IMAGENS="$(bash scripts/imagens-da-main.sh)"; then
    echo "erro: não consegui resolver as imagens da main (mensagem acima)." >&2
    exit 1
  fi
  unset FCG_REGISTRY FCG_TAG_IDENTITY FCG_TAG_CATALOG FCG_TAG_PAYMENTS
  while IFS= read -r linha; do
    chave="${linha%%=*}"
    valor="${linha#*=}"
    case "$chave" in
      FCG_REGISTRY)
        [[ "$valor" =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com$ ]] || { echo "erro: registro inválido vindo do imagens-da-main.sh: '$valor'" >&2; exit 1; }
        ;;
      FCG_TAG_IDENTITY|FCG_TAG_CATALOG|FCG_TAG_PAYMENTS)
        [[ "$valor" =~ ^[0-9a-f]{40}$ ]] || { echo "erro: tag inválida para $chave vinda do imagens-da-main.sh: '$valor'" >&2; exit 1; }
        ;;
      *)
        echo "erro: linha inesperada do imagens-da-main.sh: '$linha'" >&2
        exit 1
        ;;
    esac
    export "$chave=$valor"
  done <<<"$IMAGENS"
  for var in FCG_REGISTRY FCG_TAG_IDENTITY FCG_TAG_CATALOG FCG_TAG_PAYMENTS; do
    if [[ -z "${!var:-}" ]]; then
      echo "erro: o imagens-da-main.sh não devolveu $var." >&2
      exit 1
    fi
  done
  echo "imagens do eks: $FCG_REGISTRY, identity $FCG_TAG_IDENTITY, catalog $FCG_TAG_CATALOG, payments $FCG_TAG_PAYMENTS"
fi

# Aplica um manifest que contém imagem de serviço. No eks ele passa pelo filtro que troca
# a imagem; o resultado é renderizado inteiro antes do apply, para que uma falha do
# filtro nunca chegue ao kubectl como entrada vazia ou cortada.
apply_servico() {
  local f="$1" renderizado
  if [[ "$FCG_PERFIL" == "eks" ]]; then
    renderizado="$(bash scripts/imagem-eks.sh < "$f")"
    printf '%s\n' "$renderizado" | kubectl apply -f -
  else
    kubectl apply -f "$f"
  fi
}

# Aplica todos os .yaml de um diretório (recursivo), exceto os templates *.example.yaml.
apply_dir() {
  local dir="$1"
  find "$dir" -name '*.yaml' ! -name '*.example.yaml' -print0 \
    | xargs -0 -I{} kubectl apply -f {}
}

if [[ "$FASE_BASE" -eq 1 ]]; then
  echo "==> namespace"
  kubectl apply -f "$K8S/00-namespace.yaml"

  echo "==> 00-acesso (rbac do pipeline de entrega)"
  # o Role e o RoleBinding do pipeline tem que existir antes dos Deployments em toda
  # abertura: sem eles, numa sessao saudavel, o pipeline recebe 403. no k3d sao
  # inocuos e mantem a estrutura igual nos dois perfis.
  kubectl apply -f "$K8S/00-acesso/rbac-pipeline.yaml"

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
fi

if [[ "$FASE_SERVICOS" -eq 1 ]]; then
  echo "==> 03-services/identity (Job de migration antes do Deployment)"
  ID="$K8S/03-services/identity"
  kubectl apply -f "$ID/configmap.yaml"
  kubectl apply -f "$ID/configmap-env.yaml"
  kubectl apply -f "$ID/secret.yaml"
  kubectl apply -f "$ID/secret-jwt.yaml"
  apply_servico "$ID/migrate-job.yaml"
  echo "    aguardando migration concluir..."
  kubectl wait --for=condition=complete job/identity-migrate -n "$NS" --timeout="$TIMEOUT"
  apply_servico "$ID/deployment.yaml"
  kubectl apply -f "$ID/service.yaml"

  echo "==> 03-services/catalog (Job de migration+seed antes do Deployment)"
  CT="$K8S/03-services/catalog"
  kubectl apply -f "$CT/configmap.yaml"
  kubectl apply -f "$CT/configmap-env.yaml"
  kubectl apply -f "$CT/secret.yaml"
  # A conta de servico vem antes do Job: pod que cita conta inexistente nem e criado.
  kubectl apply -f "$CT/serviceaccount.yaml"
  apply_servico "$CT/migrate-job.yaml"
  echo "    aguardando migration+seed concluir..."
  kubectl wait --for=condition=complete job/catalog-migrate -n "$NS" --timeout="$TIMEOUT"
  apply_servico "$CT/deployment.yaml"
  kubectl apply -f "$CT/service.yaml"

  echo "==> 03-services/payments (Job de migration antes do Deployment)"
  PY="$K8S/03-services/payments"
  kubectl apply -f "$PY/configmap.yaml"
  kubectl apply -f "$PY/configmap-env.yaml"
  kubectl apply -f "$PY/secret.yaml"
  apply_servico "$PY/migrate-job.yaml"
  echo "    aguardando migration concluir..."
  kubectl wait --for=condition=complete job/payments-migrate -n "$NS" --timeout="$TIMEOUT"
  apply_servico "$PY/deployment.yaml"
  kubectl apply -f "$PY/service.yaml"

  echo "==> 04-borda (Ingress)"
  apply_dir "$K8S/04-borda"

  # O apply devolve assim que o objeto é aceito; sem esperar o rollout, o script
  # terminaria com sucesso e um serviço ainda em CrashLoop.
  echo "    aguardando os serviços ficarem prontos..."
  for deploy in identity-api catalog-api payments-api; do
    kubectl rollout status "deploy/$deploy" -n "$NS" --timeout="$TIMEOUT"
  done
fi

echo ""
echo "ok: manifestos aplicados (fase: $FCG_FASE). Acompanhe com: kubectl get pods -n $NS -w"
