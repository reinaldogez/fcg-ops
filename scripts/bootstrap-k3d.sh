#!/usr/bin/env bash
set -euo pipefail

# Cria o cluster k3d local 'fcg' para a demo da plataforma.
# Apenas provisiona o cluster; não aplica manifestos (ver apply-all.sh) nem gera segredos.
# Idempotente: se o cluster já existe, avisa e não recria.

CLUSTER="fcg"

for bin in k3d kubectl; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

if k3d cluster list --no-headers 2>/dev/null | awk '{print $1}' | grep -qx "$CLUSTER"; then
  echo "cluster '$CLUSTER' já existe — não vou recriar."
  echo "para começar do zero: k3d cluster delete $CLUSTER && bash scripts/bootstrap-k3d.sh"
else
  # Sem port mappings: o acesso às UIs é por kubectl port-forward.
  k3d cluster create "$CLUSTER" --wait
fi

# Confirma que o kubectl está apontando para o cluster recém-criado.
CONTEXT="$(kubectl config current-context)"
echo ""
echo "contexto kubectl atual: $CONTEXT"
case "$CONTEXT" in
  *"$CLUSTER"*) echo "ok: kubectl aponta para o cluster '$CLUSTER'." ;;
  *) echo "aviso: o contexto atual não parece ser o do cluster '$CLUSTER'." >&2
     echo "       ajuste com: kubectl config use-context k3d-$CLUSTER" >&2 ;;
esac
