#!/usr/bin/env bash
set -euo pipefail

# Escreve no arquivo do perfil o endpoint do dominio de busca da sessao.
# Script proprio, e nao mais uma linha do gerar-env.sh, porque o dominio nasce no apply do
# root session: quando o gerar-env.sh roda ele ainda nao existe. Tambem nao cabe no
# broker-env.sh, que fala com a AWS pela credencial de operacao; este so le um output do
# estado local do Terraform, sem chamada nenhuma a nuvem.
# Apenas preenche o arquivo; nao cria recurso nem aplica manifesto. Idempotente:
# reexecutar reescreve a mesma linha a partir do estado atual.

# Perfil de ambiente, o mesmo seletor dos outros scripts. O recuo padrao e 'eks': so a
# nuvem tem dominio de busca. Escrever o endpoint no arquivo do perfil errado nao da erro
# nenhum — o valor simplesmente nao alcanca o cluster.
FCG_PERFIL="${FCG_PERFIL:-eks}"
if [[ "$FCG_PERFIL" == "ec2" ]]; then echo "erro: o perfil ec2 foi substituido por eks" >&2; exit 1; fi
if [[ -z "${ENV_FILE:-}" ]]; then
  if [[ -f ".env.$FCG_PERFIL" ]]; then
    ENV_FILE=".env.$FCG_PERFIL"
  else
    ENV_FILE=".env"
  fi
fi
echo "perfil: $FCG_PERFIL — escrevendo em '$ENV_FILE'"

if ! command -v terraform >/dev/null 2>&1; then
  echo "erro: 'terraform' não encontrado no PATH. Instale-o e tente de novo." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "erro: '$ENV_FILE' não encontrado." >&2
  echo "      copie o template e preencha os valores reais: cp .env.example $ENV_FILE" >&2
  exit 1
fi

# O output e o host nu do dominio. O tr tira o fim de linha que o terraform no Windows pode
# deixar: um \r colado ao valor passaria pela leitura e quebraria a url so no catalog.
if ! host="$(terraform -chdir=terraform/session output -raw opensearch_endpoint | tr -d '\r\n')"; then
  echo "erro: não consegui ler o output opensearch_endpoint do root session." >&2
  echo "      ele só existe depois de o apply do terraform/session terminar." >&2
  exit 1
fi
if [[ -z "$host" ]]; then
  echo "erro: o output opensearch_endpoint do root session veio vazio." >&2
  echo "      ele só existe depois de o apply do terraform/session terminar." >&2
  exit 1
fi

# A forma e conferida antes de escrever: o certificado do dominio cobre so o nome regional,
# entao qualquer outro host falharia no handshake, longe daqui. Esquema, barra ou espaco
# no output indicam que ele mudou de forma, e o prefixo dobrado nao seria percebido.
endpoint="https://$host"
if [[ ! "$endpoint" =~ ^https://[a-z0-9.-]+\.us-east-1\.es\.amazonaws\.com$ ]]; then
  echo "erro: o output opensearch_endpoint não tem a forma esperada de host do domínio." >&2
  echo "      lido:     '$host'" >&2
  echo "      esperado: <host>.us-east-1.es.amazonaws.com, sem esquema, barra ou espaço" >&2
  exit 1
fi

# Substitui a linha da chave se ela existir, acrescenta se nao — o resto do arquivo fica
# como esta. O valor entra por variavel de ambiente do awk, e nao interpolado no programa:
# assim nenhum caractere do valor e reinterpretado.
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

set_env OPENSEARCH_ENDPOINT "$endpoint"

# O endpoint nao e segredo: imprimi-lo deixa a conferencia a vista.
echo "ok: '$ENV_FILE' atualizado:"
echo "  OPENSEARCH_ENDPOINT=$endpoint"
echo "próximo passo: FCG_PERFIL=$FCG_PERFIL bash scripts/init-secrets.sh"
