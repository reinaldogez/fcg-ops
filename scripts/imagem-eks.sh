#!/usr/bin/env bash
set -euo pipefail

# Filtro de stdin para stdout: troca a imagem de serviço do perfil k3d pela do ECR,
# presa ao commit. O manifest versionado continua apontando para o GHCR (é o que o k3d
# usa); no eks a imagem é renderizada na hora do apply, nunca escrita no repositório.
# Uso: FCG_REGISTRY=... FCG_TAG_IDENTITY=... FCG_TAG_CATALOG=... FCG_TAG_PAYMENTS=... \
#        bash scripts/imagem-eks.sh < k8s/03-services/catalog/deployment.yaml
# Valores vêm do imagens-da-main.sh. Qualquer entrada inválida encerra sem imprimir YAML:
# meio manifest num pipe para o kubectl seria aplicado como se estivesse inteiro.

for var in FCG_REGISTRY FCG_TAG_IDENTITY FCG_TAG_CATALOG FCG_TAG_PAYMENTS; do
  if [[ -z "${!var:-}" ]]; then
    echo "erro: variável ausente: $var" >&2
    exit 1
  fi
done

if [[ ! "$FCG_REGISTRY" =~ ^[A-Za-z0-9.-]+\.dkr\.ecr\.us-east-1\.amazonaws\.com$ ]]; then
  echo "erro: FCG_REGISTRY não é um registro ECR de us-east-1: '$FCG_REGISTRY'" >&2
  exit 1
fi

# A tag é o SHA completo do commit: tag móvel faria o mesmo manifest significar imagens
# diferentes em dias diferentes, e o rollback deixaria de ser reprodutível.
for var in FCG_TAG_IDENTITY FCG_TAG_CATALOG FCG_TAG_PAYMENTS; do
  if [[ ! "${!var}" =~ ^[0-9a-f]{40}$ ]]; then
    echo "erro: $var não é um SHA de commit completo (40 hex): '${!var}'" >&2
    exit 1
  fi
done

entrada="$(cat)"

saida="$(printf '%s\n' "$entrada" | sed -E \
  -e "s#ghcr\.io/reinaldogez/fcg-identity:latest([[:space:]]|\$)#${FCG_REGISTRY}/fcg-identity:${FCG_TAG_IDENTITY}\1#g" \
  -e "s#ghcr\.io/reinaldogez/fcg-catalog:latest([[:space:]]|\$)#${FCG_REGISTRY}/fcg-catalog:${FCG_TAG_CATALOG}\1#g" \
  -e "s#ghcr\.io/reinaldogez/fcg-payments:latest([[:space:]]|\$)#${FCG_REGISTRY}/fcg-payments:${FCG_TAG_PAYMENTS}\1#g")"

# Sobra de GHCR quer dizer referência que a troca não reconheceu (outra tag, outro
# serviço): no eks ela puxaria uma imagem fora do ECR, sem rastro do commit.
if grep -q 'ghcr\.io/reinaldogez/' <<<"$saida"; then
  echo "erro: sobrou referência ao GHCR depois da troca:" >&2
  grep -n 'ghcr\.io/reinaldogez/' <<<"$saida" >&2
  exit 1
fi

printf '%s\n' "$saida"
