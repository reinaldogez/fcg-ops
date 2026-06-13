#!/usr/bin/env bash
set -euo pipefail

# Materializa os Secrets reais do cluster a partir de UMA fonte única (.env não-versionado)
# e da chave RSA da demo. Deriva os valores compartilhados (senha do SA, credenciais do
# Rabbit) de um lugar só, evitando inconsistência entre arquivos.
#
# Os arquivos gerados (secret.yaml / secret-jwt.yaml) e o .env NUNCA são versionados.
# Este script NÃO inventa valores: lê o que você preencheu no .env. Idempotente — reexecutar
# regenera os arquivos a partir do .env atual (a chave RSA existente é reaproveitada).

ENV_FILE="${ENV_FILE:-.env}"
PEM="${PEM:-identity-rsa-private.pem}"
KEY_ID="fcg-identity-key-1"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      copie o template e preencha os valores reais: cp .env.example .env" >&2
  exit 1
fi

# Lê uma chave do .env de forma literal (sem expandir $ nem quebrar em ';'/espaços),
# pegando tudo após o primeiro '=' e removendo um eventual CR de fim de linha (CRLF).
get_env() {
  local key="$1"
  grep -E "^[[:space:]]*${key}=" "$ENV_FILE" | head -n1 | sed -E "s/^[[:space:]]*${key}=//" | sed 's/\r$//'
}

SA_PASSWORD="$(get_env SQLSERVER_SA_PASSWORD)"
RABBIT_USER="$(get_env RABBITMQ_USER)"
RABBIT_PASSWORD="$(get_env RABBITMQ_PASSWORD)"
DB_CONNECTION="$(get_env IDENTITY_DB_CONNECTION)"
ADMIN_PASSWORD="$(get_env ADMINSEED_PASSWORD)"

# Pré-condição: nenhuma var obrigatória pode estar vazia.
missing=0
for pair in \
  "SQLSERVER_SA_PASSWORD=$SA_PASSWORD" \
  "RABBITMQ_USER=$RABBIT_USER" \
  "RABBITMQ_PASSWORD=$RABBIT_PASSWORD" \
  "IDENTITY_DB_CONNECTION=$DB_CONNECTION" \
  "ADMINSEED_PASSWORD=$ADMIN_PASSWORD"; do
  if [[ -z "${pair#*=}" ]]; then
    echo "erro: variável obrigatória vazia ou ausente no $ENV_FILE: ${pair%%=*}" >&2
    missing=1
  fi
done
[[ "$missing" -eq 0 ]] || exit 1

# Aviso (não bloqueante) se valores ainda forem os placeholders do .example.
case "$SA_PASSWORD$RABBIT_PASSWORD$ADMIN_PASSWORD" in
  *ChangeMe*) echo "aviso: ainda há valores 'ChangeMe...' no $ENV_FILE — confira se são propositais." >&2 ;;
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
IDENTITY_SECRET="k8s/03-services/identity/secret.yaml"
JWT_SECRET="k8s/03-services/identity/secret-jwt.yaml"

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

echo "ok: Secrets reais materializados a partir de '$ENV_FILE' (fora do git):"
echo "  $SQL_SECRET"
echo "  $RABBIT_SECRET"
echo "  $IDENTITY_SECRET"
echo "  $JWT_SECRET"
echo "próximo passo: bash scripts/apply-all.sh"
