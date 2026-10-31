#!/usr/bin/env bash
set -euo pipefail

# Semeia o ECR com a imagem do commit atual da main de cada serviço. É bootstrap: vale só
# enquanto o pipeline de entrega dos serviços não publica direto no ECR.
# A imagem copiada é a que o CI do repositório publicou no GHCR para aquele commit; nada
# é construído aqui. Copia-se só a plataforma linux/amd64 porque um índice deixaria
# manifests filhos sem tag no ECR, e a regra de expiração de 1 dia apagaria esses filhos
# por baixo da tag, que passaria a apontar para nada.
# Roda do laptop, com a credencial de operação. Idempotente: tag já presente é pulada.

REGIAO="us-east-1"
SERVICOS=(identity catalog payments)

for bin in aws git crane; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

CONTA="$(aws sts get-caller-identity --query Account --output text)"
if [[ ! "$CONTA" =~ ^[0-9]{12}$ ]]; then
  echo "erro: não consegui ler a conta da credencial atual (veio '$CONTA')." >&2
  exit 1
fi
REGISTRY="$CONTA.dkr.ecr.$REGIAO.amazonaws.com"

tag_no_ecr() {
  aws ecr describe-images --region "$REGIAO" \
    --repository-name "$1" --image-ids "imageTag=$2" >/dev/null 2>&1
}

# O login só acontece se alguma imagem precisar ser copiada, e uma vez só. A senha passa
# do aws para o crane pelo pipe, sem tocar disco nem linha de comando.
LOGADO=0
login_ecr() {
  if [[ "$LOGADO" -eq 0 ]]; then
    aws ecr get-login-password --region "$REGIAO" \
      | crane auth login "$REGISTRY" -u AWS --password-stdin >/dev/null
    LOGADO=1
  fi
}

for s in "${SERVICOS[@]}"; do
  repo="fcg-$s"
  sha="$(git ls-remote "https://github.com/reinaldogez/$repo.git" refs/heads/main | cut -f1)"
  if [[ ! "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    echo "erro: não consegui ler o commit da main de $repo (veio '$sha')." >&2
    exit 1
  fi
  origem="ghcr.io/reinaldogez/$repo:$sha"
  destino="$REGISTRY/$repo:$sha"

  if tag_no_ecr "$repo" "$sha"; then
    echo "$repo:$sha ja existe no ECR"
  else
    if ! crane digest "$origem" >/dev/null 2>&1; then
      echo "erro: a tag $sha não existe em ghcr.io/reinaldogez/$repo; o CI do repositório não publicou esse commit." >&2
      exit 1
    fi
    login_ecr
    echo "copiando $origem (linux/amd64) para o ECR..."
    crane copy --platform linux/amd64 "$origem" "$destino"
  fi

  # Confere o que ficou no ECR, inclusive quando a tag já existia: uma semente antiga
  # copiada como índice teria o mesmo problema dos filhos sem tag.
  tipo="$(aws ecr describe-images --region "$REGIAO" \
    --repository-name "$repo" --image-ids "imageTag=$sha" \
    --query 'imageDetails[0].imageManifestMediaType' --output text)"
  case "$tipo" in
    application/vnd.oci.image.index.v1+json|application/vnd.docker.distribution.manifest.list.v2+json)
      echo "erro: $repo:$sha está no ECR como índice ($tipo), não como imagem de uma plataforma." >&2
      exit 1
      ;;
    None|"")
      echo "erro: $repo:$sha não aparece no ECR depois da cópia." >&2
      exit 1
      ;;
  esac
  echo "ok: $repo:$sha no ECR ($tipo)"
done

echo "próximo passo: FCG_PERFIL=eks bash scripts/apply-all.sh"
