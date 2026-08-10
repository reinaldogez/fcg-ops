#!/usr/bin/env bash
set -euo pipefail

# Descobre o broker gerenciado da sessão e escreve endereço, usuário e senha no .env local.
# Roda NA INSTÂNCIA, não no laptop: a autenticação é o perfil de instância, que concede
# exatamente as três chamadas usadas aqui (listagem, descrição e leitura do segredo).
# Apenas preenche o .env; não cria recurso, não aplica manifesto e não gera senha.
# Idempotente: reexecutar reescreve as três chaves a partir do estado atual da nuvem.
#
# A senha nunca é impressa. O broker é procurado pelo NOME, que é estável entre sessões —
# o identificador muda a cada criação e não serve de chave de descoberta.

ENV_FILE="${ENV_FILE:-.env}"
BROKER_NAME="${BROKER_NAME:-fcg-broker}"
SECRET_NAME="${SECRET_NAME:-fcg-broker-credencial}"

for bin in aws jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      copie o template e preencha os valores reais: cp .env.example .env" >&2
  exit 1
fi

# Descoberta pelo nome. A listagem não aceita escopo de recurso na política, então é a
# única chamada que enxerga todos os brokers da conta: o filtro pelo nome é aqui.
BROKER_ID="$(aws mq list-brokers \
  --query "BrokerSummaries[?BrokerName=='${BROKER_NAME}'].BrokerId" \
  --output text)"

if [[ -z "$BROKER_ID" || "$BROKER_ID" == "None" ]]; then
  echo "erro: nenhum broker chamado '$BROKER_NAME' nesta conta/região." >&2
  echo "      o broker é criado por sessão: terraform -chdir=terraform/session apply" >&2
  exit 1
fi

# Mais de um casamento é ambiguidade real, não detalhe: escolher um seria escolher errado
# metade das vezes, e o sintoma apareceria só no consumo.
if [[ "$(printf '%s\n' $BROKER_ID | wc -l)" -gt 1 ]]; then
  echo "erro: mais de um broker chamado '$BROKER_NAME' — não sei qual usar." >&2
  exit 1
fi

# O endereço sai como URI de transporte (esquema e porta inclusos), mas RabbitMq__Host
# espera o host nu: a porta viaja em RABBITMQ_PORT e o TLS em RABBITMQ_USE_SSL.
BROKER_ENDPOINT="$(aws mq describe-broker \
  --broker-id "$BROKER_ID" \
  --query "BrokerInstances[0].Endpoints[0]" \
  --output text)"

if [[ -z "$BROKER_ENDPOINT" || "$BROKER_ENDPOINT" == "None" ]]; then
  echo "erro: o broker '$BROKER_NAME' ainda não publicou endereço." >&2
  echo "      ele leva ~11min para ficar de pé; confira o estado antes de repetir." >&2
  exit 1
fi

BROKER_HOST="${BROKER_ENDPOINT#*://}"
BROKER_HOST="${BROKER_HOST%%:*}"

# A partir daqui a credencial está em variável. O rastreamento é desligado no trecho e
# restaurado depois: um 'set -x' ligado por fora imprimiria a linha inteira, senha e tudo.
TRACE_ANTERIOR=""
case "$-" in
  *x*) TRACE_ANTERIOR="on" ;;
esac
{ set +x; } 2>/dev/null

CREDENCIAL="$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET_NAME" \
  --query SecretString \
  --output text)"

BROKER_USER="$(printf '%s' "$CREDENCIAL" | jq -r '.username')"
BROKER_PASSWORD="$(printf '%s' "$CREDENCIAL" | jq -r '.password')"
unset CREDENCIAL

if [[ -z "$BROKER_USER" || "$BROKER_USER" == "null" ]] \
  || [[ -z "$BROKER_PASSWORD" || "$BROKER_PASSWORD" == "null" ]]; then
  echo "erro: o segredo '$SECRET_NAME' não traz o par usuário/senha esperado." >&2
  exit 1
fi

# Substitui a linha da chave se ela existir, acrescenta se não — o resto do arquivo fica
# como está. O valor entra por variável de ambiente do awk, e não interpolado no programa:
# assim nenhum caractere do valor é reinterpretado, e a senha não aparece na linha de comando.
set_env() {
  local key="$1" value="$2" tmp
  tmp="$(mktemp)"
  KEY="$key" VALUE="$value" awk '
    BEGIN { key = ENVIRON["KEY"]; value = ENVIRON["VALUE"]; escrito = 0 }
    $0 ~ "^[[:space:]]*" key "=" { if (!escrito) { print key "=" value; escrito = 1 } ; next }
    { print }
    END { if (!escrito) print key "=" value }
  ' "$ENV_FILE" > "$tmp"
  mv "$tmp" "$ENV_FILE"
}

set_env RABBITMQ_HOST "$BROKER_HOST"
set_env RABBITMQ_USER "$BROKER_USER"
set_env RABBITMQ_PASSWORD "$BROKER_PASSWORD"
unset BROKER_PASSWORD

if [[ -n "$TRACE_ANTERIOR" ]]; then
  set -x
fi

echo "ok: broker '$BROKER_NAME' descoberto e '$ENV_FILE' atualizado:"
echo "  RABBITMQ_HOST=$BROKER_HOST"
echo "  RABBITMQ_USER=$BROKER_USER"
echo "  RABBITMQ_PASSWORD=(escrita no arquivo; não exibida)"
echo "lembre-se de conferir RABBITMQ_PORT=5671 e RABBITMQ_USE_SSL=true para a nuvem."
echo "próximo passo: bash scripts/topologia.sh"
