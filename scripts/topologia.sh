#!/usr/bin/env bash
set -euo pipefail

# Cria a topologia que a função serverless assina, pela API de gerenciamento do broker.
# Na sessão de nuvem nenhum consumidor container sobe para declará-la: o mapeamento de
# origem de eventos consome fila que já tem de existir, e fila ausente não dá erro —
# dá silêncio. Este script é quem a cria.
# Apenas cria exchange, fila e associação; não publica mensagem e não apaga nada.
#
# Idempotente por construção, e não por verificação prévia: a criação é upsert (a segunda
# execução responde 204 no lugar de 201) e a associação repetida é operação nula. Checar
# existência antes abriria uma janela entre a checagem e a criação, sem ganho nenhum.
#
# As credenciais vêm do .env, preenchido pelo broker-env.sh. A senha só entra na
# autenticação do curl: nenhuma linha daqui a imprime.

ENV_FILE="${ENV_FILE:-.env}"

if ! command -v curl >/dev/null 2>&1; then
  echo "erro: 'curl' não encontrado no PATH. Instale-o e tente de novo." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      copie o template e preencha os valores reais: cp .env.example .env" >&2
  exit 1
fi

# Lê uma chave do .env de forma literal (sem expandir $ nem quebrar em ';'/espaços),
# pegando tudo após o primeiro '=' e removendo um eventual CR de fim de linha (CRLF).
# Chave ausente devolve string vazia e sucesso: sob 'set -e' o grep sem casamento
# derrubaria o script aqui, antes da checagem que nomeia a variável faltante.
get_env() {
  local key="$1"
  grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | head -n1 | sed -E "s/^[[:space:]]*${key}=//" | sed 's/\r$//' || true
}

RABBITMQ_HOST="$(get_env RABBITMQ_HOST)"
RABBITMQ_USER="$(get_env RABBITMQ_USER)"
RABBITMQ_PASSWORD="$(get_env RABBITMQ_PASSWORD)"

# Pré-condição: as três são preenchidas pelo broker-env.sh. Vazia aqui quase sempre
# significa que aquele passo não rodou nesta sessão.
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
  echo "      rode antes, na instância: bash scripts/broker-env.sh" >&2
  exit 1
fi

# A API de gerenciamento é o management padrão do RabbitMQ, em 443. O vhost é a barra,
# que na URL vai codificada como %2F.
API="https://${RABBITMQ_HOST}/api"
VHOST="%2F"

# Os nomes são escritos literais, um por linha, e nunca montados por concatenação: a
# função assina exatamente estas filas, e uma letra de diferença não falha em lugar
# nenhum — só deixa o consumidor apontado para uma fila que não existe. Literal é o que
# a revisão e a busca no repositório conseguem conferir.
EXCHANGE_USUARIO="user-created"
FILA_USUARIO="user-created.fcg-notifications-fn"
EXCHANGE_PAGAMENTO="payment-processed"
FILA_PAGAMENTO="payment-processed.fcg-notifications-fn"

# O rastreamento é desligado enquanto a credencial circula e restaurado no fim: um
# 'set -x' ligado por fora imprimiria a linha do curl inteira, com usuário e senha.
TRACE_ANTERIOR=""
case "$-" in
  *x*) TRACE_ANTERIOR="on" ;;
esac
{ set +x; } 2>/dev/null

# Sem '-v': o modo verboso do curl imprime o cabeçalho de autorização. O código de
# resposta é o que interessa — 201 na criação, 204 quando o objeto já estava lá.
chamar() {
  local metodo="$1" caminho="$2" corpo="$3" descricao="$4" codigo

  codigo="$(curl -sS -o /dev/null -w '%{http_code}' \
    -X "$metodo" \
    -u "${RABBITMQ_USER}:${RABBITMQ_PASSWORD}" \
    -H 'content-type: application/json' \
    -d "$corpo" \
    "${API}${caminho}")"

  case "$codigo" in
    2*) echo "  ok $codigo — $descricao" ;;
    *)
      echo "erro: $descricao falhou com HTTP $codigo" >&2
      return 1
      ;;
  esac
}

# Uma exchange fanout durável, uma fila durável e a associação entre elas, por evento.
# Durável dos dois lados porque o broker da sessão reinicia sem avisar, e topologia
# perdida no reinício voltaria ao sintoma silencioso que este script existe para evitar.
declarar_par() {
  local exchange="$1" fila="$2"

  chamar PUT "/exchanges/${VHOST}/${exchange}" \
    '{"type":"fanout","durable":true}' \
    "exchange ${exchange}"

  chamar PUT "/queues/${VHOST}/${fila}" \
    '{"durable":true}' \
    "fila ${fila}"

  chamar POST "/bindings/${VHOST}/e/${exchange}/q/${fila}" \
    '{"routing_key":"","arguments":{}}' \
    "associação ${exchange} -> ${fila}"
}

echo "criando a topologia em ${RABBITMQ_HOST}:"
declarar_par "$EXCHANGE_USUARIO" "$FILA_USUARIO"
declarar_par "$EXCHANGE_PAGAMENTO" "$FILA_PAGAMENTO"

unset RABBITMQ_PASSWORD

if [[ -n "$TRACE_ANTERIOR" ]]; then
  set -x
fi

echo "ok: topologia criada."
echo "conferir a contagem de associações (deve haver uma por par, não duas):"
echo "  curl -sS -u \"\$RABBITMQ_USER:\$RABBITMQ_PASSWORD\" ${API}/bindings"
