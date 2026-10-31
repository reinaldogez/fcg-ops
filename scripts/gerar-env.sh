#!/usr/bin/env bash
set -euo pipefail

# Gera o .env.eks da sessão a partir do .env.example: senhas novas, broker em TLS, read
# model gerenciado e o emissor do token apontando para o gateway. Roda do laptop, na raiz
# do repositório, antes do init-secrets.sh. O broker fica por conta do broker-env.sh, que
# reescreve host, usuário e senha dele depois de o session/ subir.
# Uso: bash scripts/gerar-env.sh [--substituir]
#
# As senhas são por sessão: trocar no meio dela quebra os bancos de pé, que só leem a
# senha no primeiro boot do volume. Por isso um .env.eks existente só é sobrescrito com
# --substituir. A saída mostra só os nomes das chaves; nenhum valor gerado é impresso,
# e o arquivo não é copiado para nenhum outro lugar.

ORIGEM=".env.example"
DESTINO=".env.eks"

SUBSTITUIR=0
for arg in "$@"; do
  case "$arg" in
    --substituir) SUBSTITUIR=1 ;;
    *)
      echo "erro: argumento desconhecido: '$arg' (use --substituir para sobrescrever $DESTINO)" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$ORIGEM" ]]; then
  echo "erro: '$ORIGEM' não encontrado; rode na raiz do repositório." >&2
  exit 1
fi
if [[ -e "$DESTINO" && "$SUBSTITUIR" -ne 1 ]]; then
  echo "erro: '$DESTINO' já existe. as senhas dele são as dos bancos desta sessão." >&2
  echo "      para gerar outras (sessão nova, volumes novos): bash scripts/gerar-env.sh --substituir" >&2
  exit 1
fi
if ! command -v openssl >/dev/null 2>&1; then
  echo "erro: 'openssl' não encontrado no PATH. Instale-o e tente de novo." >&2
  exit 1
fi

# Emissor do token: a URL do gateway sem barra final. Com a barra, todo token válido
# recebe 401 nas rotas protegidas, porque o emissor deixa de casar caractere a caractere.
if [[ -n "${FCG_API_ISSUER:-}" ]]; then
  ISSUER="$FCG_API_ISSUER"
else
  if ! command -v terraform >/dev/null 2>&1; then
    echo "erro: FCG_API_ISSUER vazio e 'terraform' não encontrado para ler o output api_issuer." >&2
    exit 1
  fi
  ISSUER="$(terraform -chdir=terraform/platform output -raw api_issuer)"
fi
ISSUER="$(printf '%s' "$ISSUER" | tr -d '\r\n')"
if [[ -z "$ISSUER" ]]; then
  echo "erro: emissor vazio (FCG_API_ISSUER ou output api_issuer do platform)." >&2
  exit 1
fi
if [[ "$ISSUER" == */ ]]; then
  echo "erro: o emissor termina em '/': '$ISSUER'. use o output api_issuer, não api_invoke_url." >&2
  exit 1
fi
if [[ "$ISSUER" != https://* ]]; then
  echo "erro: o emissor precisa ser uma URL https: '$ISSUER'." >&2
  exit 1
fi

# O rastreamento é desligado enquanto as senhas existem em variável: um 'set -x' ligado
# por fora imprimiria cada uma.
{ set +x; } 2>/dev/null

# Maiúscula, minúscula, dígito e especial: passa na política do SQL Server e na validação
# de senha do identity. O tr tira o \r que o openssl do Windows deixa no fim da linha.
gera_senha() {
  local hex
  hex="$(openssl rand -hex 12 | tr -d '\r\n')"
  if [[ ! "$hex" =~ ^[0-9a-f]{24}$ ]]; then
    echo "erro: o openssl não devolveu 24 hex." >&2
    return 1
  fi
  printf 'Fcg-%s-9a' "$hex"
}

SENHA_SQL="$(gera_senha)"
SENHA_ADMIN="$(gera_senha)"
SENHA_REDIS="$(gera_senha)"
SENHA_PG_CATALOG="$(gera_senha)"
SENHA_PG_PAYMENTS="$(gera_senha)"
SENHA_GRAFANA="$(gera_senha)"
# A do broker é reescrita pelo broker-env.sh com a credencial real do broker gerenciado;
# gerá-la aqui só evita que um placeholder conhecido sobreviva no arquivo.
SENHA_RABBIT="$(gera_senha)"

umask 077
TMP="$(mktemp "./.env.eks.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

# Cada chave do template é trocada exatamente uma vez; as connection strings mantêm a
# forma do template e só trocam o campo Password=. Os valores entram pelo ambiente do awk,
# nunca interpolados no programa nem na linha de comando.
SENHA_SQL="$SENHA_SQL" SENHA_ADMIN="$SENHA_ADMIN" SENHA_REDIS="$SENHA_REDIS" \
SENHA_PG_CATALOG="$SENHA_PG_CATALOG" SENHA_PG_PAYMENTS="$SENHA_PG_PAYMENTS" \
SENHA_GRAFANA="$SENHA_GRAFANA" SENHA_RABBIT="$SENHA_RABBIT" ISSUER="$ISSUER" \
awk '
  BEGIN {
    valor["SQLSERVER_SA_PASSWORD"] = ENVIRON["SENHA_SQL"]
    valor["ADMINSEED_PASSWORD"] = ENVIRON["SENHA_ADMIN"]
    valor["REDIS_PASSWORD"] = ENVIRON["SENHA_REDIS"]
    valor["POSTGRES_CATALOG_PASSWORD"] = ENVIRON["SENHA_PG_CATALOG"]
    valor["POSTGRES_PAYMENTS_PASSWORD"] = ENVIRON["SENHA_PG_PAYMENTS"]
    valor["GRAFANA_ADMIN_PASSWORD"] = ENVIRON["SENHA_GRAFANA"]
    valor["RABBITMQ_PASSWORD"] = ENVIRON["SENHA_RABBIT"]
    valor["RABBITMQ_HOST"] = "preenchido-pelo-broker-env"
    valor["RABBITMQ_PORT"] = "5671"
    valor["RABBITMQ_USE_SSL"] = "true"
    valor["DYNAMODB_SERVICE_URL"] = ""
    valor["JWT_ISSUER"] = ENVIRON["ISSUER"]
    valor["JWT_PUBLIC_BASE_URL"] = ENVIRON["ISSUER"]
    senha_da_conexao["IDENTITY_DB_CONNECTION"] = ENVIRON["SENHA_SQL"]
    senha_da_conexao["CATALOG_DB_CONNECTION"] = ENVIRON["SENHA_PG_CATALOG"]
    senha_da_conexao["PAYMENTS_DB_CONNECTION"] = ENVIRON["SENHA_PG_PAYMENTS"]
  }
  { sub(/\r$/, "") }
  /^[A-Z0-9_]+=/ {
    chave = substr($0, 1, index($0, "=") - 1)
    resto = substr($0, index($0, "=") + 1)
    if (chave in valor) {
      print chave "=" valor[chave]; visto[chave]++; next
    }
    if (chave in senha_da_conexao) {
      n = sub(/Password=[^;]*/, "Password=" senha_da_conexao[chave], resto)
      if (n != 1) { print "erro: " chave " sem campo Password= no template" > "/dev/stderr"; falhou = 1 }
      print chave "=" resto; visto[chave]++; next
    }
  }
  { print }
  END {
    for (c in valor) if (visto[c] != 1) { print "erro: chave " c " aparece " visto[c] + 0 " vez(es) no template" > "/dev/stderr"; falhou = 1 }
    for (c in senha_da_conexao) if (visto[c] != 1) { print "erro: chave " c " aparece " visto[c] + 0 " vez(es) no template" > "/dev/stderr"; falhou = 1 }
    exit falhou
  }
' "$ORIGEM" > "$TMP"

mv -f "$TMP" "$DESTINO"
trap - EXIT

echo "ok: $DESTINO gerado a partir de $ORIGEM. chaves preenchidas:"
for chave in SQLSERVER_SA_PASSWORD IDENTITY_DB_CONNECTION ADMINSEED_PASSWORD REDIS_PASSWORD \
  POSTGRES_CATALOG_PASSWORD CATALOG_DB_CONNECTION POSTGRES_PAYMENTS_PASSWORD \
  PAYMENTS_DB_CONNECTION GRAFANA_ADMIN_PASSWORD RABBITMQ_PASSWORD RABBITMQ_HOST \
  RABBITMQ_PORT RABBITMQ_USE_SSL DYNAMODB_SERVICE_URL JWT_ISSUER JWT_PUBLIC_BASE_URL; do
  echo "  $chave"
done
echo "próximo passo: FCG_PERFIL=eks bash scripts/broker-env.sh (depois do apply do session/)"
