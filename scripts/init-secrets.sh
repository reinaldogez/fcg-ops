#!/usr/bin/env bash
set -euo pipefail

# Materializa, a partir de UMA fonte única (.env não-versionado) e da chave RSA da demo:
# os Secrets reais do cluster e os ConfigMaps de ambiente (configmap-env.yaml), que
# carregam o que varia entre k3d e a nuvem sem ser credencial. Deriva os valores
# compartilhados (senha do SA, credenciais do Rabbit) de um lugar só, evitando
# inconsistência entre arquivos.
#
# Os arquivos gerados (secret.yaml / secret-jwt.yaml / configmap-env.yaml) e o .env
# NUNCA são versionados.
# Este script NÃO inventa valores: lê o que você preencheu no .env. Idempotente — reexecutar
# regenera os arquivos a partir do .env atual (a chave RSA existente é reaproveitada).

# Perfil de ambiente, o mesmo seletor que o apply-all.sh usa. Cada perfil tem seu proprio
# arquivo de valores (.env.k3d, .env.ec2), porque host, porta e TLS do broker diferem entre
# eles: alternar editando um arquivo unico deixa o disco num estado meio a meio, com chave
# de um ambiente e chave de outro. ENV_FILE explicito continua vencendo, e quem tem so o
# .env antigo segue funcionando pelo recuo.
FCG_PERFIL="${FCG_PERFIL:-k3d}"
if [[ -z "${ENV_FILE:-}" ]]; then
  if [[ -f ".env.$FCG_PERFIL" ]]; then
    ENV_FILE=".env.$FCG_PERFIL"
  else
    ENV_FILE=".env"
  fi
fi
echo "perfil: $FCG_PERFIL — lendo valores de '$ENV_FILE'"

PEM="${PEM:-identity-rsa-private.pem}"
KEY_ID="fcg-identity-key-1"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      copie o template e preencha os valores reais: cp .env.example $ENV_FILE" >&2
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

SA_PASSWORD="$(get_env SQLSERVER_SA_PASSWORD)"
RABBIT_USER="$(get_env RABBITMQ_USER)"
RABBIT_PASSWORD="$(get_env RABBITMQ_PASSWORD)"
DB_CONNECTION="$(get_env IDENTITY_DB_CONNECTION)"
ADMIN_PASSWORD="$(get_env ADMINSEED_PASSWORD)"
REDIS_PASSWORD="$(get_env REDIS_PASSWORD)"
POSTGRES_CATALOG_PASSWORD="$(get_env POSTGRES_CATALOG_PASSWORD)"
CATALOG_DB_CONNECTION="$(get_env CATALOG_DB_CONNECTION)"
POSTGRES_PAYMENTS_PASSWORD="$(get_env POSTGRES_PAYMENTS_PASSWORD)"
PAYMENTS_DB_CONNECTION="$(get_env PAYMENTS_DB_CONNECTION)"
GRAFANA_ADMIN_USER="$(get_env GRAFANA_ADMIN_USER)"
GRAFANA_ADMIN_PASSWORD="$(get_env GRAFANA_ADMIN_PASSWORD)"

# Valores que variam entre k3d e a nuvem. Nao sao credencial, entao vao para ConfigMap
# gerado (nao-versionado) em vez de Secret — o ConfigMap versionado so guarda o que e
# identico nos dois ambientes.
RABBITMQ_HOST="$(get_env RABBITMQ_HOST)"
RABBITMQ_PORT="$(get_env RABBITMQ_PORT)"
RABBITMQ_USE_SSL="$(get_env RABBITMQ_USE_SSL)"
JWT_ISSUER="$(get_env JWT_ISSUER)"
JWT_PUBLIC_BASE_URL="$(get_env JWT_PUBLIC_BASE_URL)"
DYNAMODB_SERVICE_URL="$(get_env DYNAMODB_SERVICE_URL)"

# Pré-condição: nenhuma var obrigatória pode estar vazia. As duas que podem ser vazias
# por natureza são cobradas logo abaixo, por outra regra.
missing=0
for pair in \
  "SQLSERVER_SA_PASSWORD=$SA_PASSWORD" \
  "RABBITMQ_USER=$RABBIT_USER" \
  "RABBITMQ_PASSWORD=$RABBIT_PASSWORD" \
  "IDENTITY_DB_CONNECTION=$DB_CONNECTION" \
  "ADMINSEED_PASSWORD=$ADMIN_PASSWORD" \
  "REDIS_PASSWORD=$REDIS_PASSWORD" \
  "POSTGRES_CATALOG_PASSWORD=$POSTGRES_CATALOG_PASSWORD" \
  "CATALOG_DB_CONNECTION=$CATALOG_DB_CONNECTION" \
  "POSTGRES_PAYMENTS_PASSWORD=$POSTGRES_PAYMENTS_PASSWORD" \
  "PAYMENTS_DB_CONNECTION=$PAYMENTS_DB_CONNECTION" \
  "GRAFANA_ADMIN_USER=$GRAFANA_ADMIN_USER" \
  "GRAFANA_ADMIN_PASSWORD=$GRAFANA_ADMIN_PASSWORD" \
  "RABBITMQ_HOST=$RABBITMQ_HOST" \
  "RABBITMQ_PORT=$RABBITMQ_PORT" \
  "RABBITMQ_USE_SSL=$RABBITMQ_USE_SSL" \
  "JWT_ISSUER=$JWT_ISSUER"; do
  if [[ -z "${pair#*=}" ]]; then
    echo "erro: variável obrigatória vazia ou ausente no $ENV_FILE: ${pair%%=*}" >&2
    missing=1
  fi
done

# Duas variaveis sao legitimamente vazias em um dos ambientes — JWT_PUBLIC_BASE_URL em
# k3d, DYNAMODB_SERVICE_URL na nuvem. Para elas a exigencia e a chave estar declarada no
# arquivo, nao ter valor: assim o ambiente que nao a usa passa, mas um nome digitado
# errado ainda falha em vez de virar string vazia em silencio.
for key in JWT_PUBLIC_BASE_URL DYNAMODB_SERVICE_URL; do
  if ! grep -qE "^[[:space:]]*${key}=" "$ENV_FILE"; then
    echo "erro: variável obrigatória vazia ou ausente no $ENV_FILE: $key" >&2
    echo "      ela pode ficar vazia, mas precisa estar declarada." >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 1

# Aviso (não bloqueante) se valores ainda forem os placeholders do .example.
case "$SA_PASSWORD$RABBIT_PASSWORD$ADMIN_PASSWORD$REDIS_PASSWORD$POSTGRES_CATALOG_PASSWORD$POSTGRES_PAYMENTS_PASSWORD" in
  *ChangeMe*) echo "aviso: ainda há valores 'ChangeMe...' no $ENV_FILE — confira se são propositais." >&2 ;;
esac

# O Redis nao precisa de aviso de casamento: a mesma REDIS_PASSWORD alimenta o
# --requirepass do servidor e o Redis__Password do consumidor, os dois derivados
# daqui. Nao ha segunda copia da senha para divergir.

# Mesma regra para o Postgres do catalog: a senha do servidor (POSTGRES_PASSWORD)
# tem de bater com a embutida na connection string do catalog.
case "$CATALOG_DB_CONNECTION" in
  *"Password=$POSTGRES_CATALOG_PASSWORD"*) ;;
  *) echo "aviso: CATALOG_DB_CONNECTION não embute a mesma senha de POSTGRES_CATALOG_PASSWORD no $ENV_FILE — devem casar." >&2 ;;
esac

# Mesma regra para o Postgres do payments: a senha do servidor (POSTGRES_PASSWORD)
# tem de bater com a embutida na connection string do payments.
case "$PAYMENTS_DB_CONNECTION" in
  *"Password=$POSTGRES_PAYMENTS_PASSWORD"*) ;;
  *) echo "aviso: PAYMENTS_DB_CONNECTION não embute a mesma senha de POSTGRES_PAYMENTS_PASSWORD no $ENV_FILE — devem casar." >&2 ;;
esac

# Chave RSA: gera só se ainda não existir; caso contrário reaproveita.
if [[ ! -f "$PEM" ]]; then
  echo "chave RSA '$PEM' ausente — gerando..."
  bash scripts/gen-rsa-key.sh "$PEM" >/dev/null
fi

# Escapa um valor para scalar YAML entre aspas simples (só ' precisa ser dobrado).
sq() { printf "%s" "$1" | sed "s/'/''/g"; }

SQL_SECRET="k8s/01-infra/sqlserver-identity/secret.yaml"
RABBIT_SECRET="k8s/01-infra/rabbitmq/secret.yaml"
REDIS_SECRET="k8s/01-infra/redis/secret.yaml"
POSTGRES_CATALOG_SECRET="k8s/01-infra/postgres-catalog/secret.yaml"
POSTGRES_PAYMENTS_SECRET="k8s/01-infra/postgres-payments/secret.yaml"
IDENTITY_SECRET="k8s/03-services/identity/secret.yaml"
JWT_SECRET="k8s/03-services/identity/secret-jwt.yaml"
CATALOG_SECRET="k8s/03-services/catalog/secret.yaml"
PAYMENTS_SECRET="k8s/03-services/payments/secret.yaml"
GRAFANA_SECRET="k8s/02-observability/grafana/secret.yaml"
IDENTITY_ENV="k8s/03-services/identity/configmap-env.yaml"
CATALOG_ENV="k8s/03-services/catalog/configmap-env.yaml"
PAYMENTS_ENV="k8s/03-services/payments/configmap-env.yaml"

cat > "$SQL_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: sqlserver-identity-secret
  namespace: fcg
type: Opaque
stringData:
  MSSQL_SA_PASSWORD: '$(sq "$SA_PASSWORD")'
EOF

cat > "$RABBIT_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: rabbitmq-secret
  namespace: fcg
type: Opaque
stringData:
  RABBITMQ_DEFAULT_USER: '$(sq "$RABBIT_USER")'
  RABBITMQ_DEFAULT_PASS: '$(sq "$RABBIT_PASSWORD")'
EOF

cat > "$REDIS_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: redis-secret
  namespace: fcg
type: Opaque
stringData:
  REDIS_PASSWORD: '$(sq "$REDIS_PASSWORD")'
EOF

cat > "$POSTGRES_CATALOG_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-catalog-secret
  namespace: fcg
type: Opaque
stringData:
  POSTGRES_PASSWORD: '$(sq "$POSTGRES_CATALOG_PASSWORD")'
EOF

cat > "$POSTGRES_PAYMENTS_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: postgres-payments-secret
  namespace: fcg
type: Opaque
stringData:
  POSTGRES_PASSWORD: '$(sq "$POSTGRES_PAYMENTS_PASSWORD")'
EOF

cat > "$IDENTITY_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: identity-secret
  namespace: fcg
type: Opaque
stringData:
  ConnectionStrings__DefaultConnection: '$(sq "$DB_CONNECTION")'
  RabbitMq__Username: '$(sq "$RABBIT_USER")'
  RabbitMq__Password: '$(sq "$RABBIT_PASSWORD")'
  AdminSeed__DefaultPassword: '$(sq "$ADMIN_PASSWORD")'
EOF

# Secret JWT: PEM como block scalar (cada linha indentada em 4 espaços), CR removido.
{
  cat <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: identity-jwt
  namespace: fcg
type: Opaque
stringData:
  Jwt__RsaPrivateKeyPem: |
EOF
  sed 's/\r$//; s/^/    /' "$PEM"
  echo "  Jwt__KeyId: '$(sq "$KEY_ID")'"
} > "$JWT_SECRET"

cat > "$CATALOG_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: catalog-secret
  namespace: fcg
type: Opaque
stringData:
  ConnectionStrings__Catalog: '$(sq "$CATALOG_DB_CONNECTION")'
  RabbitMq__Username: '$(sq "$RABBIT_USER")'
  RabbitMq__Password: '$(sq "$RABBIT_PASSWORD")'
  Redis__Password: '$(sq "$REDIS_PASSWORD")'
EOF

cat > "$PAYMENTS_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: payments-secret
  namespace: fcg
type: Opaque
stringData:
  ConnectionStrings__Payments: '$(sq "$PAYMENTS_DB_CONNECTION")'
  RabbitMq__Username: '$(sq "$RABBIT_USER")'
  RabbitMq__Password: '$(sq "$RABBIT_PASSWORD")'
EOF

cat > "$GRAFANA_SECRET" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: grafana-secret
  namespace: fcg
type: Opaque
stringData:
  GF_SECURITY_ADMIN_USER: '$(sq "$GRAFANA_ADMIN_USER")'
  GF_SECURITY_ADMIN_PASSWORD: '$(sq "$GRAFANA_ADMIN_PASSWORD")'
EOF

cat > "$IDENTITY_ENV" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: identity-env
  namespace: fcg
data:
  RabbitMq__Host: '$(sq "$RABBITMQ_HOST")'
  RabbitMq__Port: '$(sq "$RABBITMQ_PORT")'
  RabbitMq__UseSsl: '$(sq "$RABBITMQ_USE_SSL")'
  Jwt__Issuer: '$(sq "$JWT_ISSUER")'
  Jwt__PublicBaseUrl: '$(sq "$JWT_PUBLIC_BASE_URL")'
EOF

cat > "$CATALOG_ENV" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: catalog-env
  namespace: fcg
data:
  RabbitMq__Host: '$(sq "$RABBITMQ_HOST")'
  RabbitMq__Port: '$(sq "$RABBITMQ_PORT")'
  RabbitMq__UseSsl: '$(sq "$RABBITMQ_USE_SSL")'
  Jwt__Issuer: '$(sq "$JWT_ISSUER")'
  DynamoDb__ServiceUrl: '$(sq "$DYNAMODB_SERVICE_URL")'
EOF

cat > "$PAYMENTS_ENV" <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: payments-env
  namespace: fcg
data:
  RabbitMq__Host: '$(sq "$RABBITMQ_HOST")'
  RabbitMq__Port: '$(sq "$RABBITMQ_PORT")'
  RabbitMq__UseSsl: '$(sq "$RABBITMQ_USE_SSL")'
EOF

echo "ok: Secrets reais materializados a partir de '$ENV_FILE' (fora do git):"
echo "  $SQL_SECRET"
echo "  $RABBIT_SECRET"
echo "  $REDIS_SECRET"
echo "  $POSTGRES_CATALOG_SECRET"
echo "  $POSTGRES_PAYMENTS_SECRET"
echo "  $IDENTITY_SECRET"
echo "  $JWT_SECRET"
echo "  $CATALOG_SECRET"
echo "  $PAYMENTS_SECRET"
echo "  $GRAFANA_SECRET"
echo "ok: ConfigMaps de ambiente materializados (fora do git):"
echo "  $IDENTITY_ENV"
echo "  $CATALOG_ENV"
echo "  $PAYMENTS_ENV"
echo "próximo passo: bash scripts/apply-all.sh"
