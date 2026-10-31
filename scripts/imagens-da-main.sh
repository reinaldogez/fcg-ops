#!/usr/bin/env bash
set -euo pipefail

# Resolve, para cada serviço, a imagem do ECR que corresponde ao commit atual da main do
# repositório dele, e confere que ela existe. Roda do laptop, com a credencial de operação.
# Saída padrão: exatamente quatro linhas CHAVE=valor, consumidas pelo apply-all.sh no
# perfil eks. Mensagens vão para a saída de erro.
#
# Imagem ausente é erro, nunca motivo para cair em outra: subir uma imagem que não é a da
# main faria a sessão demonstrar um código diferente do que está no repositório.

REGIAO="us-east-1"
SERVICOS=(identity catalog payments)

for bin in aws git; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

# A conta vem da credencial em uso, e não de um literal no repositório.
CONTA="$(aws sts get-caller-identity --query Account --output text)"
if [[ ! "$CONTA" =~ ^[0-9]{12}$ ]]; then
  echo "erro: não consegui ler a conta da credencial atual (veio '$CONTA')." >&2
  exit 1
fi
REGISTRY="$CONTA.dkr.ecr.$REGIAO.amazonaws.com"

declare -A TAG
for s in "${SERVICOS[@]}"; do
  sha="$(git ls-remote "https://github.com/reinaldogez/fcg-$s.git" refs/heads/main | cut -f1)"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "erro: não consegui ler o commit da main de fcg-$s (veio '$sha')." >&2
    exit 1
  fi

  if ! detalhe="$(aws ecr describe-images \
      --region "$REGIAO" \
      --repository-name "fcg-$s" \
      --image-ids "imageTag=$sha" 2>&1 >/dev/null)"; then
    echo "erro: a imagem fcg-$s:$sha nao esta no ECR; rode o pipeline do servico (ou scripts/semear-ecr.sh enquanto o CD nao existir)" >&2
    if [[ -n "$detalhe" ]]; then
      echo "      resposta do aws: $(head -n1 <<<"$detalhe")" >&2
    fi
    exit 1
  fi
  TAG[$s]="$sha"
done

echo "FCG_REGISTRY=$REGISTRY"
echo "FCG_TAG_IDENTITY=${TAG[identity]}"
echo "FCG_TAG_CATALOG=${TAG[catalog]}"
echo "FCG_TAG_PAYMENTS=${TAG[payments]}"
