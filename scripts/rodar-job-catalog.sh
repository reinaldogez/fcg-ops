#!/usr/bin/env bash
set -euo pipefail

# Roda sob demanda um dos Jobs de manutencao do catalog, com a imagem que o Deployment esta
# servindo agora.
# Uso: bash scripts/rodar-job-catalog.sh <reprojetar|reindexar>
#
# A imagem vem do Deployment, e nao do manifest: o Job tem que rodar o mesmo codigo que
# esta servindo, e na nuvem a tag do commit so existe no cluster depois de cada deploy. O
# filtro imagem-eks.sh nao serve aqui porque resolve o HEAD da main, que pode estar a
# frente do que esta implantado.
# O Job anterior e apagado antes: Job concluido nao roda de novo, e reaplicar o mesmo nome
# so devolveria "unchanged".

NS="fcg"
CT="k8s/03-services/catalog"
TETO=300
INTERVALO=5
IMAGEM_LOCAL="ghcr.io/reinaldogez/fcg-catalog:latest"

uso() {
  echo "uso: bash scripts/rodar-job-catalog.sh <reprojetar|reindexar>" >&2
  exit 2
}

# O argumento e conferido antes de qualquer chamada ao cluster.
[[ "$#" -eq 1 ]] || uso
case "$1" in
  reprojetar|reindexar) JOB="$1" ;;
  *) uso ;;
esac
NOME="catalog-$JOB"
MANIFEST="$CT/$JOB-job.yaml"

FCG_PERFIL="${FCG_PERFIL:-k3d}"
case "$FCG_PERFIL" in
  k3d|eks) ;;
  ec2) echo "erro: o perfil ec2 foi substituido por eks" >&2; exit 1 ;;
  *)
    echo "erro: FCG_PERFIL inválido: '$FCG_PERFIL' (use 'k3d' ou 'eks')" >&2
    exit 1
    ;;
esac

# Guarda de contexto, a mesma do apply-all.sh: o mesmo laptop fala com o k3d e com o eks, e
# o Job de um perfil rodado no cluster do outro escreveria no indice ou no read model errado.
CONTEXTO_ATUAL="$(kubectl config current-context 2>/dev/null || true)"
case "$FCG_PERFIL" in
  k3d)
    CONTEXTO_ESPERADO="k3d-fcg"
    [[ "$CONTEXTO_ATUAL" == "k3d-fcg" ]] && CONTEXTO_OK=1 || CONTEXTO_OK=0
    ;;
  eks)
    CONTEXTO_ESPERADO="terminado em ':cluster/fcg-eks'"
    [[ "$CONTEXTO_ATUAL" == *":cluster/fcg-eks" ]] && CONTEXTO_OK=1 || CONTEXTO_OK=0
    ;;
esac
if [[ "$CONTEXTO_OK" -ne 1 ]]; then
  echo "erro: o contexto atual do kubectl não casa com o perfil '$FCG_PERFIL'." >&2
  echo "      atual:    '${CONTEXTO_ATUAL:-<nenhum>}'" >&2
  echo "      esperado: $CONTEXTO_ESPERADO" >&2
  exit 1
fi

IMAGEM="$(kubectl get deploy/catalog-api -n "$NS" \
  -o jsonpath='{.spec.template.spec.containers[?(@.name=="catalog-api")].image}' 2>/dev/null || true)"
if [[ -z "$IMAGEM" ]]; then
  echo "erro: não li a imagem do deploy/catalog-api em '$NS' — o catalog não está implantado." >&2
  exit 1
fi

# A imagem lida tambem e conferida contra a forma do perfil: no eks, uma imagem do GHCR no
# Deployment e sinal de implantacao fora do caminho, e o Job herdaria o mesmo desvio.
case "$FCG_PERFIL" in
  k3d)
    [[ "$IMAGEM" == "$IMAGEM_LOCAL" ]] && FORMA_OK=1 || FORMA_OK=0
    FORMA="$IMAGEM_LOCAL"
    ;;
  eks)
    [[ "$IMAGEM" =~ ^[0-9]{12}\.dkr\.ecr\.us-east-1\.amazonaws\.com/fcg-catalog:[0-9a-f]{40}$ ]] && FORMA_OK=1 || FORMA_OK=0
    FORMA="<conta>.dkr.ecr.us-east-1.amazonaws.com/fcg-catalog:<commit de 40 hex>"
    ;;
esac
if [[ "$FORMA_OK" -ne 1 ]]; then
  echo "erro: a imagem do deploy/catalog-api não tem a forma do perfil '$FCG_PERFIL'." >&2
  echo "      lida:     '$IMAGEM'" >&2
  echo "      esperado: $FORMA" >&2
  exit 1
fi

# Renderiza inteiro antes de mexer no cluster: uma troca que nao casou exatamente uma vez
# nunca chega ao kubectl.
if [[ ! -f "$MANIFEST" ]]; then
  echo "erro: manifest '$MANIFEST' não encontrado." >&2
  exit 1
fi
TROCAS="$(grep -cF "image: $IMAGEM_LOCAL" "$MANIFEST" || true)"
if [[ "$TROCAS" -ne 1 ]]; then
  echo "erro: esperava exatamente uma imagem '$IMAGEM_LOCAL' em '$MANIFEST', achei $TROCAS." >&2
  exit 1
fi
RENDERIZADO="$(IMAGEM_LOCAL="$IMAGEM_LOCAL" IMAGEM="$IMAGEM" awk '
  BEGIN { de = "image: " ENVIRON["IMAGEM_LOCAL"]; para = "image: " ENVIRON["IMAGEM"] }
  { i = index($0, de); if (i > 0) { $0 = substr($0, 1, i - 1) para substr($0, i + length(de)) } ; print }
' "$MANIFEST")"
if [[ "$FCG_PERFIL" == "eks" ]] && grep -qF "ghcr.io/reinaldogez/" <<<"$RENDERIZADO"; then
  echo "erro: sobrou referência a ghcr.io/reinaldogez/ no Job renderizado para o eks." >&2
  exit 1
fi

echo "==> $NOME com a imagem $IMAGEM"
kubectl delete job "$NOME" -n "$NS" --ignore-not-found --wait=true
printf '%s\n' "$RENDERIZADO" | kubectl apply -f -

ler_logs() {
  # sem o teto curto, cada leitura com o pod ainda no init esperaria 20 s pelo pod.
  kubectl logs "job/$NOME" -n "$NS" -c "$JOB" --tail=50 --pod-running-timeout=5s 2>/dev/null || true
}

# Espera a condicao final do Job. A palavra e conferida inteira: 'Complete' e 'Failed'
# convivem com outras condicoes verdadeiras na mesma lista.
# O log e guardado a cada sondagem porque, com reinicio no proprio pod, o controlador
# apaga o pod quando o Job estoura as tentativas: depois do 'Failed' nao ha mais de onde
# ler o motivo da falha.
ESTADO=""
FIM=0
ULTIMO_LOG=""
decorrido=0
while (( decorrido < TETO )); do
  sleep "$INTERVALO"
  decorrido=$(( decorrido + INTERVALO ))
  ESTADO="$(kubectl get job "$NOME" -n "$NS" \
    -o jsonpath='{.status.conditions[?(@.status=="True")].type}' 2>/dev/null || true)"
  if [[ " $ESTADO " == *" Complete "* ]]; then FIM=complete; break; fi
  if [[ " $ESTADO " == *" Failed "* ]]; then FIM=failed; break; fi
  log="$(ler_logs)"
  [[ -n "$log" ]] && ULTIMO_LOG="$log"
done

echo "==> logs de job/$NOME (últimas 50 linhas)"
log="$(ler_logs)"
if [[ -n "$log" ]]; then
  printf '%s\n' "$log"
elif [[ -n "$ULTIMO_LOG" ]]; then
  echo "(o pod do Job já não existe; último log lido durante a espera)"
  printf '%s\n' "$ULTIMO_LOG"
else
  echo "(nenhum log disponível)"
fi
echo "imagem usada: $IMAGEM"

case "$FIM" in
  complete)
    echo "ok: $NOME concluído em ~${decorrido}s."
    ;;
  failed)
    echo "erro: $NOME falhou (condições: '$ESTADO')." >&2
    exit 1
    ;;
  *)
    echo "erro: $NOME não terminou em ${TETO}s (condições lidas: '${ESTADO:-<nenhuma>}')." >&2
    exit 1
    ;;
esac
