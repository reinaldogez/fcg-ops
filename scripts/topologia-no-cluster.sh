#!/usr/bin/env bash
set -euo pipefail

# O rastreamento sai antes de qualquer leitura de credencial: um 'bash -x' por fora
# imprimiria a linha que lê a senha do .env e a que escreve o Secret. Não é restaurado,
# porque nada daqui em diante pode ser rastreado sem expor a credencial.
{ set +x; } 2>/dev/null

# Cria a topologia da função serverless a partir de um pod efêmero no cluster da sessão.
# Uso: bash scripts/topologia-no-cluster.sh (da raiz do repositório)
#
# Por que um pod: o broker gerenciado é privado na VPC e o laptop não o alcança, e a
# instância que antes rodava o topologia.sh de dentro da VPC não existe mais. O pod está na
# VPC, e o grupo de segurança dos nós já tem 443 liberado no broker.
#
# Por que o topologia.sh vai inteiro e sem alteração, montado de um ConfigMap: a topologia
# continua tendo uma única definição, a que a revisão confere. Uma segunda cópia adaptada
# para o pod divergiria em silêncio, e a função assinaria uma fila que ninguém criou.
#
# Por que o Secret é efêmero: a credencial só precisa existir no cluster enquanto o pod
# roda. Ela entra por arquivo temporário (nunca por argumento, que aparece na lista de
# processos), e pod, Secret e ConfigMap são apagados na saída, com sucesso ou não.

NS="fcg"
POD="topologia"
CONFIGMAP="topologia-script"
SECRET="topologia-env"
SCRIPT="scripts/topologia.sh"
INTERVALO=5
# o padrão dá folga sobre o pull da imagem e o apk add; a variável existe para o teste.
TETO="${TOPOLOGIA_TETO:-180}"

if [[ ! "$TETO" =~ ^[0-9]+$ ]]; then
  echo "erro: TOPOLOGIA_TETO inválido: '$TETO' (segundos, inteiro)" >&2
  exit 1
fi

# Só o perfil eks: no k3d o RabbitMQ é do próprio cluster e os consumidores declaram a
# topologia ao subir. Rodar isto lá criaria filas que ninguém consome.
FCG_PERFIL="${FCG_PERFIL:-eks}"
if [[ "$FCG_PERFIL" != "eks" ]]; then
  echo "erro: FCG_PERFIL '$FCG_PERFIL' não se aplica: a topologia da função só existe no broker gerenciado (perfil eks)." >&2
  exit 1
fi
if [[ -z "${ENV_FILE:-}" ]]; then
  if [[ -f ".env.$FCG_PERFIL" ]]; then
    ENV_FILE=".env.$FCG_PERFIL"
  else
    ENV_FILE=".env"
  fi
fi
echo "perfil: $FCG_PERFIL — lendo valores de '$ENV_FILE'"

if ! command -v kubectl >/dev/null 2>&1; then
  echo "erro: 'kubectl' não encontrado no PATH." >&2
  exit 1
fi

# Guarda de contexto, a mesma do apply-all.sh: o mesmo laptop fala com o k3d e com o eks.
CONTEXTO_ATUAL="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CONTEXTO_ATUAL" != *":cluster/fcg-eks" ]]; then
  echo "erro: o contexto atual do kubectl não casa com o perfil '$FCG_PERFIL'." >&2
  echo "      atual:    '${CONTEXTO_ATUAL:-<nenhum>}'" >&2
  echo "      esperado: terminado em ':cluster/fcg-eks'" >&2
  exit 1
fi

if [[ ! -f "$SCRIPT" ]]; then
  echo "erro: '$SCRIPT' não encontrado — rode da raiz do repositório." >&2
  exit 1
fi
if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      rode antes, do laptop: bash scripts/broker-env.sh" >&2
  exit 1
fi

# Lê uma chave do .env de forma literal, como nos outros scripts. Chave ausente devolve
# vazio e sucesso, para a checagem abaixo nomear a variável faltante.
get_env() {
  local key="$1"
  grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | head -n1 | sed -E "s/^[[:space:]]*${key}=//" | sed 's/\r$//' || true
}

RABBITMQ_HOST="$(get_env RABBITMQ_HOST)"
RABBITMQ_USER="$(get_env RABBITMQ_USER)"
RABBITMQ_PASSWORD="$(get_env RABBITMQ_PASSWORD)"

# Toda a validação vem antes do primeiro objeto criado no cluster.
missing=0
for pair in \
  "RABBITMQ_HOST=$RABBITMQ_HOST" \
  "RABBITMQ_USER=$RABBITMQ_USER" \
  "RABBITMQ_PASSWORD=$RABBITMQ_PASSWORD"; do
  if [[ -z "${pair#*=}" ]]; then
    echo "erro: variável obrigatória vazia ou ausente no $ENV_FILE: ${pair%%=*}" >&2
    missing=1
  fi
done
if [[ "$missing" -ne 0 ]]; then
  echo "      rode antes, do laptop: bash scripts/broker-env.sh" >&2
  exit 1
fi

# A limpeza roda em qualquer saída a partir daqui. A ordem segue a dependência: o pod
# usa o Secret e o ConfigMap, e sai primeiro.
SECRET_ARQ=""
limpar() {
  local codigo=$?
  if [[ -n "$SECRET_ARQ" ]]; then
    rm -f "$SECRET_ARQ"
  fi
  echo "==> limpeza"
  kubectl delete pod "$POD" -n "$NS" --ignore-not-found || true
  kubectl delete secret "$SECRET" -n "$NS" --ignore-not-found || true
  kubectl delete configmap "$CONFIGMAP" -n "$NS" --ignore-not-found || true
  exit "$codigo"
}
trap limpar EXIT

echo "==> configmap/$CONFIGMAP (o $SCRIPT, sem alteração)"
kubectl create configmap "$CONFIGMAP" -n "$NS" \
  --from-file=topologia.sh="$SCRIPT" \
  --dry-run=client -o yaml | kubectl apply -f -

# Aspas simples no YAML, com a aspa simples dobrada: o valor é literal, sem escape a
# interpretar. O printf é embutido do bash e o sed lê a senha da entrada padrão, então ela
# não aparece como argumento de processo nenhum.
sq() { printf "%s" "$1" | sed "s/'/''/g"; }

echo "==> secret/$SECRET (efêmero)"
SECRET_ARQ="$(mktemp)"
chmod 600 "$SECRET_ARQ"
{
  printf 'apiVersion: v1\nkind: Secret\nmetadata:\n  name: %s\n  namespace: %s\ntype: Opaque\nstringData:\n' "$SECRET" "$NS"
  printf "  RABBITMQ_HOST: '%s'\n" "$(sq "$RABBITMQ_HOST")"
  printf "  RABBITMQ_USER: '%s'\n" "$(sq "$RABBITMQ_USER")"
  printf "  RABBITMQ_PASSWORD: '%s'\n" "$(sq "$RABBITMQ_PASSWORD")"
} > "$SECRET_ARQ"
kubectl apply -f "$SECRET_ARQ"
rm -f "$SECRET_ARQ"
SECRET_ARQ=""
unset RABBITMQ_PASSWORD

# Imagem: o topologia.sh exige bash e curl. A curlimages/curl não tem bash; a alpine
# instala os dois em segundos, e os pods já têm saída para a internet. O printf monta o
# .env que o topologia.sh lê a partir das variáveis do Secret, dentro do contêiner, e o
# Kubernetes não expande '$VAR' (só '$(VAR)'). Os nomes abaixo são os mesmos das
# variáveis do topo; o manifest não leva credencial nenhuma.
echo "==> pod/$POD"
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: topologia
  namespace: fcg
spec:
  restartPolicy: Never
  containers:
    - name: topologia
      image: alpine:3.20
      command:
        - sh
        - -c
        - |-
          apk add --no-cache bash curl >/dev/null && printf 'RABBITMQ_HOST=%s\nRABBITMQ_USER=%s\nRABBITMQ_PASSWORD=%s\n' "$RABBITMQ_HOST" "$RABBITMQ_USER" "$RABBITMQ_PASSWORD" > /tmp/env && ENV_FILE=/tmp/env bash /scripts/topologia.sh
      envFrom:
        - secretRef:
            name: topologia-env
      volumeMounts:
        - name: script
          mountPath: /scripts
          readOnly: true
  volumes:
    - name: script
      configMap:
        name: topologia-script
YAML

# Espera a fase final do pod. Com restartPolicy Never, Succeeded e Failed são terminais.
FASE=""
decorrido=0
while (( decorrido < TETO )); do
  sleep "$INTERVALO"
  decorrido=$(( decorrido + INTERVALO ))
  FASE="$(kubectl get pod "$POD" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  case "$FASE" in
    Succeeded|Failed) break ;;
  esac
done

# O topologia.sh não imprime a senha, então o log inteiro pode ir para a tela. Pod que
# não chegou a rodar não tem log, e isso não pode impedir a limpeza.
echo "==> logs de pod/$POD"
kubectl logs "pod/$POD" -n "$NS" || echo "(nenhum log disponível)"
echo "fase final: ${FASE:-<nenhuma>}"

case "$FASE" in
  Succeeded)
    echo "ok: topologia criada pelo pod em ~${decorrido}s."
    ;;
  Failed)
    echo "erro: o pod terminou em Failed (log acima)." >&2
    exit 1
    ;;
  *)
    echo "erro: o pod não terminou em ${TETO}s." >&2
    exit 1
    ;;
esac
