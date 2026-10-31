#!/usr/bin/env bash
set -euo pipefail

# Prepara o cluster eks da sessão para receber a aplicação: classe de disco, controlador
# de balanceador, Traefik e a ligação do Traefik ao target group da borda. Roda do laptop,
# com a credencial de operação, depois do apply do session/ e antes do apply-all.sh.
# Cada passo é idempotente: reexecutar no meio de uma sessão reconcilia em vez de duplicar.
# Não aplica a aplicação (é o apply-all.sh) e não cria recurso fora do cluster: o target
# group e o balanceador são do Terraform.

CLUSTER="fcg-eks"
REGIAO="us-east-1"
VPC_NOME="fcg-vpc"
LBC_VERSAO="3.6.0"
TRAEFIK_VERSAO="42.1.0"
EKS_DIR="k8s/eks"
TGB_GERADO="$EKS_DIR/tgb.gerado.yaml"

for bin in aws kubectl helm terraform; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 1
  fi
done

echo "==> 1/9 kubeconfig do $CLUSTER"
aws eks update-kubeconfig --name "$CLUSTER" --region "$REGIAO"
# Daqui em diante todo comando do kubectl e do helm vai para o contexto atual: confirma-se
# que é o eks antes de aplicar qualquer coisa.
CONTEXTO="$(kubectl config current-context)"
if [[ "$CONTEXTO" != *":cluster/$CLUSTER" ]]; then
  echo "erro: o contexto atual é '$CONTEXTO', esperado terminado em ':cluster/$CLUSTER'." >&2
  exit 1
fi

echo "==> 2/9 classe de disco gp3"
kubectl apply -f "$EKS_DIR/storageclass-gp3.yaml"

echo "==> 3/9 repositórios de charts"
adicionar_repo() {
  local nome="$1" url="$2" saida
  if ! saida="$(helm repo add "$nome" "$url" 2>&1)"; then
    if ! grep -q 'already exists' <<<"$saida"; then
      echo "$saida" >&2
      exit 1
    fi
  fi
}
adicionar_repo eks https://aws.github.io/eks-charts
adicionar_repo traefik https://traefik.github.io/charts
helm repo update eks traefik

echo "==> 4/9 aws-load-balancer-controller $LBC_VERSAO"
VPC_ID="$(aws ec2 describe-vpcs --region "$REGIAO" \
  --filters "Name=tag:Name,Values=$VPC_NOME" \
  --query 'Vpcs[].VpcId' --output text)"
if [[ ! "$VPC_ID" =~ ^vpc-[0-9a-f]+$ ]]; then
  echo "erro: não achei uma VPC única com Name=$VPC_NOME (veio '$VPC_ID')." >&2
  exit 1
fi
# Sem o grupo de segurança de backend: o controlador só registra alvos no target group do
# Terraform, e o grupo que ele criaria sobraria órfão no fechamento da sessão.
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --version "$LBC_VERSAO" \
  --namespace kube-system \
  --set clusterName="$CLUSTER" \
  --set region="$REGIAO" \
  --set vpcId="$VPC_ID" \
  --set enableBackendSecurityGroup=false \
  --wait

echo "==> 5/9 namespace do traefik"
kubectl apply -f "$EKS_DIR/traefik-namespace.yaml"

echo "==> 6/9 traefik $TRAEFIK_VERSAO"
helm upgrade --install traefik traefik/traefik \
  --version "$TRAEFIK_VERSAO" \
  --namespace traefik \
  -f "$EKS_DIR/traefik-values.yaml" \
  --wait

echo "==> 7/9 tipo do Service do traefik"
# Um Service LoadBalancer aqui criaria um balanceador fora do Terraform, que nenhum
# destroy do session/ apagaria.
TIPO="$(kubectl get svc traefik -n traefik -o jsonpath='{.spec.type}')"
if [[ "$TIPO" != "ClusterIP" ]]; then
  echo "erro: o Service traefik nasceu '$TIPO', esperado ClusterIP. confira $EKS_DIR/traefik-values.yaml." >&2
  exit 1
fi

echo "==> 8/9 TargetGroupBinding"
TG_ARN="$(terraform -chdir=terraform/platform output -raw tg_arn)"
if [[ ! "$TG_ARN" =~ ^arn:aws:elasticloadbalancing:${REGIAO}:[0-9]{12}:targetgroup/[A-Za-z0-9-]+/[0-9a-f]+$ ]]; then
  echo "erro: o output tg_arn do platform não tem forma de ARN de target group (veio '$TG_ARN')." >&2
  exit 1
fi
# O ARN identifica a conta: vai para um arquivo gerado, fora do git, e não para o manifest.
sed -E "s#^([[:space:]]*targetGroupARN:)[[:space:]]*TG_ARN[[:space:]]*\$#\1 ${TG_ARN}#" \
  "$EKS_DIR/tgb.yaml" > "$TGB_GERADO"
if ! grep -qE "^[[:space:]]*targetGroupARN: ${TG_ARN}\$" "$TGB_GERADO"; then
  echo "erro: a renderização de $TGB_GERADO não trocou o ARN." >&2
  exit 1
fi
kubectl apply -f "$TGB_GERADO"

echo "==> 9/9 alvos saudáveis no target group"
# Duas réplicas do Traefik, dois alvos: com menos, a borda ainda não tem para onde mandar.
saudaveis=0
for _ in $(seq 1 30); do
  saudaveis="$(aws elbv2 describe-target-health --region "$REGIAO" \
    --target-group-arn "$TG_ARN" \
    --query "length(TargetHealthDescriptions[?TargetHealth.State=='healthy'])" \
    --output text)"
  if [[ "$saudaveis" -ge 2 ]]; then
    break
  fi
  sleep 10
done
if [[ "$saudaveis" -lt 2 ]]; then
  echo "erro: depois de 5 min o target group tem $saudaveis alvo(s) healthy, esperado 2." >&2
  aws elbv2 describe-target-health --region "$REGIAO" --target-group-arn "$TG_ARN" \
    --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason]' \
    --output text >&2 || true
  exit 1
fi

echo ""
echo "ok: cluster $CLUSTER preparado ($saudaveis alvos healthy no target group)."
echo "próximo passo: FCG_PERFIL=eks bash scripts/apply-all.sh"
