#!/usr/bin/env bash
set -euo pipefail

# Esvazia o cluster eks da sessão na ordem que deixa a conta limpa para o destroy do
# session/. O que o cluster criou por conta própria (volumes dos PVCs, registros no target
# group, grupos de segurança do controlador) não está no estado do Terraform: se o
# destroy vier antes, isso sobra na conta, cobrando, ou trava a remoção da rede.
# A ordem foi a provada no spike: aplicação, volumes, ligação com a borda, Traefik,
# controlador. Não roda terraform: o destroy é passo humano, por plano salvo.

CLUSTER="fcg-eks"
REGIAO="us-east-1"
TG_NOME="fcg-traefik"
ESPERA_TENTATIVAS=30   # 30 x 10 s = 5 min
ESPERA_INTERVALO=10

for bin in aws kubectl helm; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

# O primeiro passo apaga o namespace fcg do contexto atual: no k3d ele também existe, e
# apagá-lo ali por engano custaria os bancos locais.
CONTEXTO="$(kubectl config current-context 2>/dev/null || true)"
if [[ "$CONTEXTO" != *":cluster/$CLUSTER" ]]; then
  echo "erro: o contexto atual é '${CONTEXTO:-<nenhum>}', esperado terminado em ':cluster/$CLUSTER'." >&2
  exit 1
fi

echo "==> 1/7 namespace fcg"
kubectl delete ns fcg --ignore-not-found --wait=true --timeout=600s

echo "==> 2/7 volumes dos PVCs do namespace fcg"
# Com reclaimPolicy Delete o driver apaga o volume depois do PVC, de forma assíncrona: o
# namespace some antes do volume.
volumes=""
for _ in $(seq 1 "$ESPERA_TENTATIVAS"); do
  volumes="$(aws ec2 describe-volumes --region "$REGIAO" \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=fcg" \
    --query 'Volumes[].VolumeId' --output text)"
  if [[ -z "$volumes" || "$volumes" == "None" ]]; then
    volumes=""
    break
  fi
  sleep "$ESPERA_INTERVALO"
done
if [[ -n "$volumes" ]]; then
  echo "erro: depois de 5 min ainda há volumes do namespace fcg: $volumes" >&2
  exit 1
fi

echo "==> 3/7 ligação do Traefik com o target group"
TG_ARN="$(aws elbv2 describe-target-groups --region "$REGIAO" --names "$TG_NOME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
if [[ ! "$TG_ARN" =~ ^arn:aws:elasticloadbalancing: ]]; then
  echo "erro: não achei o target group '$TG_NOME' (veio '$TG_ARN')." >&2
  exit 1
fi
if kubectl get crd targetgroupbindings.elbv2.k8s.aws >/dev/null 2>&1; then
  kubectl delete targetgroupbinding --all -n traefik --ignore-not-found
fi
# O controlador tira os alvos do target group ao apagar a ligação; alvo que sobrasse
# apontaria para um IP que o próximo cluster pode reusar.
alvos=""
for _ in $(seq 1 "$ESPERA_TENTATIVAS"); do
  alvos="$(aws elbv2 describe-target-health --region "$REGIAO" --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].Target.Id' --output text)"
  if [[ -z "$alvos" || "$alvos" == "None" ]]; then
    alvos=""
    break
  fi
  sleep "$ESPERA_INTERVALO"
done
if [[ -n "$alvos" ]]; then
  echo "erro: depois de 5 min o target group '$TG_NOME' ainda tem alvos: $alvos" >&2
  exit 1
fi

echo "==> 4/7 traefik"
if helm status traefik -n traefik >/dev/null 2>&1; then
  helm uninstall traefik -n traefik
fi
kubectl wait --for=delete svc/traefik -n traefik --timeout=120s 2>/dev/null || true
if kubectl get svc traefik -n traefik >/dev/null 2>&1; then
  echo "erro: o Service traefik ainda existe depois de 120 s." >&2
  exit 1
fi

echo "==> 5/7 aws-load-balancer-controller"
# Por último entre os componentes: é ele quem desfaz a ligação e os grupos que criou, e
# sem ele de pé nada mais limpa o que ficou.
if helm status aws-load-balancer-controller -n kube-system >/dev/null 2>&1; then
  helm uninstall aws-load-balancer-controller -n kube-system
fi

echo "==> 6/7 grupos de segurança do controlador"
grupos="$(aws ec2 describe-security-groups --region "$REGIAO" \
  --filters "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
  --query 'SecurityGroups[].GroupId' --output text)"
if [[ -n "$grupos" && "$grupos" != "None" ]]; then
  echo "erro: sobraram grupos de segurança do controlador: $grupos" >&2
  echo "      eles prendem a rede e fazem o destroy do session/ falhar; remova-os antes." >&2
  exit 1
fi

echo "==> 7/7 próximo passo (humano)"
echo "ok: cluster $CLUSTER esvaziado; nada que ele criou sobrou na conta."
echo "agora o plano de destruição do session/, salvo e revisado antes de aplicar:"
echo "  terraform -chdir=terraform/session plan -destroy -out=../plans/session-destroy.tfplan"
