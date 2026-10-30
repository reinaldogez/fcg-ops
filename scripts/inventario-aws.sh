#!/usr/bin/env bash
set -euo pipefail

# Confere o inventario do satelite na conta: o que tem de estar de pe continua de pe, e o
# que e cobrado por hora nao sobrou ligado. Roda na abertura e no fechamento de toda sessao
# de nuvem, e e a prova do fechamento -- destruir o root de sessao e intencao; este comando
# e o que confirma.
#
# So le. Nao cria, nao altera e nao remove recurso nenhum: achar excedente e motivo de
# relatorio e codigo de saida, nunca de limpeza automatica. A decisao de destruir e humana
# e mora no root correspondente.
#
# Codigos de saida: 0 quando o inventario bate; 1 quando sobrou algo cobrado por hora;
# 2 quando falta peca do permanente. Sao dois codigos porque as duas falhas pedem acoes
# opostas -- uma manda destruir, a outra manda aplicar.

# Sob MSYS (o bash que acompanha o Git para Windows), argumento que comeca por '/' e
# reescrito para caminho do Windows antes de chegar ao executavel. O prefixo do grupo de log
# comeca por '/', entao a chamada chega deformada e a API recusa. A variavel desliga a
# conversao para este processo e os filhos; fora do MSYS ela nao tem efeito nenhum, entao
# fica no topo em vez de virar instrucao para quem roda -- instrucao se esquece, e o sintoma
# e o inventario dizer que falta um recurso que esta la.
export MSYS2_ARG_CONV_EXCL='*'

# Consulta que falha aborta por sinal (ver 'aws_'), e o sinal vira o codigo 2 -- o mesmo de
# peca faltando, porque a acao que ele pede e a mesma: olhar antes de dar a sessao por
# fechada. O trap existe para o sinal nao virar codigo 143 nem imprimir 'Terminated'.
trap 'exit 2' TERM

REGIAO="${AWS_REGION:-us-east-1}"
PREFIXO="${NAME_PREFIX:-fcg-}"
NAMESPACE="${NAMESPACE_DESCOBERTA:-fcg.local}"
RETENCAO_ESPERADA="${RETENCAO_LOG:-14}"

for bin in aws jq; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "erro: '$bin' não encontrado no PATH. Instale-o e tente de novo." >&2
    exit 2
  fi
done

# A regiao viaja explicita em toda chamada em vez de depender do ambiente: um inventario
# que consultasse a regiao errada sairia zero com a conta inteira ligada do outro lado.
#
# A chamada que falha aborta o inventario com a mensagem do proprio 'aws'. Achar nada e
# resposta valida e sai zero com saida vazia; nao conseguir perguntar nao e -- e as duas
# coisas eram indistinguiveis enquanto o erro ia para /dev/null e o codigo de saida era
# descartado. O efeito era o relatorio anunciar ausencia de recurso existente, que manda
# aplicar o que ja esta aplicado.
# O 'kill' no lugar de 'exit' nao e estilo: a consulta roda dentro de '$(...)', e ali 'exit'
# encerraria so a subshell -- o '|| true' da consulta engoliria o codigo e o inventario
# seguiria ate o fim, imprimindo ausencia para o permanente e, pior, 'inexistente' para as
# linhas proibidas, que e a leitura que manda encerrar a sessao com o broker cobrando.
aws_() {
  local saida
  if ! saida="$(aws --region "$REGIAO" "$@" 2>&1)"; then
    {
      echo "erro: consulta à AWS falhou (região ${REGIAO}); inventário abortado."
      echo "  aws $*"
      printf '%s\n' "$saida" | sed 's/^/  /'
    } >&2
    kill -TERM $$
  fi
  printf '%s' "$saida"
}

# ---------------------------------------------------------------------------
# consultas do permanente
#
# Cada funcao imprime uma linha por recurso encontrado, e nada quando nao encontra. O laco
# de verificacao so conta linhas: quem sabe qual chamada faz o que e a tabela, nao o laco.
#
# Toda consulta termina em '|| true', e ele protege o 'grep -v', nao a chamada: o grep sai 1
# quando nao sobra linha, e sob 'set -e' uma ausencia legitima derrubaria o script. Falha da
# chamada e caso diferente e nao passa por aqui -- morre no 'aws_', com a mensagem da API.
# ---------------------------------------------------------------------------

q_api() {
  aws_ apigatewayv2 get-apis \
    --query "Items[?Name=='${PREFIXO}api'].ApiId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# O authorizer pende da API, entao a consulta so faz sentido depois de resolver o
# identificador dela. API ausente devolve vazio aqui tambem, e as duas linhas do relatorio
# acusam ausencia -- que e a verdade: sem API nao ha authorizer.
q_authorizer() {
  local api_id
  api_id="$(q_api | head -n1)"
  [[ -n "$api_id" ]] || return 0

  aws_ apigatewayv2 get-authorizers \
    --api-id "$api_id" \
    --query "Items[?Name=='${PREFIXO}jwt'].AuthorizerId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# A integracao tambem pende da API. Conta so as privadas: e uma, e todas as rotas apontam
# para ela -- uma segunda seria resto de borda anterior.
q_integracao() {
  local api_id
  api_id="$(q_api | head -n1)"
  [[ -n "$api_id" ]] || return 0

  aws_ apigatewayv2 get-integrations \
    --api-id "$api_id" \
    --query "Items[?ConnectionType=='VPC_LINK'].IntegrationId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# O estado entra na consulta: link que falhou na criacao existe com o nome certo e nao
# entrega nada, e o sintoma seria 503 no gateway com o cluster de pe.
q_vpc_link() {
  aws_ apigatewayv2 get-vpc-links \
    --query "Items[?Name=='${PREFIXO}vpc-link-borda' && VpcLinkStatus=='AVAILABLE'].VpcLinkId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Sem '--names': com nome inexistente a chamada falha em vez de devolver vazio, e a falha
# abortaria o inventario justamente no caso que ele precisa relatar.
q_nlb() {
  aws_ elbv2 describe-load-balancers \
    --query "LoadBalancers[?LoadBalancerName=='${PREFIXO}nlb' && Scheme=='internal'].LoadBalancerArn" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_tg() {
  aws_ elbv2 describe-target-groups \
    --query "TargetGroups[?TargetGroupName=='${PREFIXO}traefik'].TargetGroupArn" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# A retencao entra na consulta, e nao numa checagem a parte: grupo de log sem validade
# acumula para sempre e cobra armazenamento, entao um grupo com retencao errada nao e o
# recurso esperado -- e outra coisa com o mesmo nome.
q_log_gateway() {
  aws_ logs describe-log-groups \
    --log-group-name-prefix "/aws/apigateway/${PREFIXO}api" \
    --query "logGroups[?retentionInDays==\`${RETENCAO_ESPERADA}\`].logGroupName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_segredo_broker() {
  aws_ secretsmanager list-secrets \
    --query "SecretList[?Name=='${PREFIXO}broker-credencial'].ARN" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# A imutabilidade entra na consulta pelo mesmo motivo da retencao do grupo de log:
# repositorio com tag mutavel tem o nome certo e deixa o cluster rodar imagem diferente da
# que o pipeline publicou.
q_repositorios() {
  aws_ ecr describe-repositories \
    --query "repositories[?imageTagMutability=='IMMUTABLE' && contains(['${PREFIXO}identity','${PREFIXO}catalog','${PREFIXO}payments'], repositoryName)].repositoryName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# O provedor nao tem nome nem etiqueta pela qual casar: o ARN termina no endereco do emissor.
q_oidc() {
  aws_ iam list-open-id-connect-providers \
    --query "OpenIDConnectProviderList[?ends_with(Arn,'/token.actions.githubusercontent.com')].Arn" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_roles_cd() {
  aws_ iam list-roles \
    --query "Roles[?starts_with(RoleName,'${PREFIXO}cd-')].RoleName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_roles_pod() {
  aws_ iam list-roles \
    --query "Roles[?starts_with(RoleName,'${PREFIXO}pod-')].RoleName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# ---------------------------------------------------------------------------
# consultas do que nao pode existir
#
# A listagem de brokers nao aceita escopo de recurso, entao o filtro pelo prefixo e aqui.
# Funcao e mapeamento de origem nascem no repositorio da funcao, fora deste: eles sao
# procurados pelo prefixo de nome, e nao pela etiqueta de projeto, justamente porque nao ha
# garantia de que o outro repositorio a aplique -- um inventario que so olhasse etiqueta
# diria "limpo" com a funcao ligada.
#
# O mesmo vale para o que os controladores do cluster criam por conta propria: volumes de
# PVC, grupos de seguranca e balanceadores do controlador nao estao em estado de Terraform
# nenhum, e destruir o root de sessao nao os leva. Sao procurados pela marca que o proprio
# controlador poe.
# ---------------------------------------------------------------------------

q_cluster() {
  aws_ eks list-clusters \
    --query "clusters[?starts_with(@,'${PREFIXO}')]" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Os nos sao casados pela etiqueta que o grupo de nos gerenciado poe, e por qualquer estado
# que ainda cobre volume: no parado nao cobra hora de computacao, mas o disco segue cobrando.
q_nos() {
  aws_ ec2 describe-instances \
    --filters "Name=tag:eks:cluster-name,Values=${PREFIXO}eks" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# A maquina da fase anterior, em qualquer estado que nao seja terminada: parada ela ainda
# cobra o volume, e nada mais a usa.
q_instancia_f3() {
  aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PREFIXO}cluster" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Qualquer endereco alocado com a etiqueta do projeto: associado ou solto, cobra por hora,
# e nada do permanente usa endereco fixo.
q_ip_fixo() {
  aws_ ec2 describe-addresses \
    --filters "Name=tag:projeto,Values=fcg" \
    --query 'Addresses[].AllocationId' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_volumes_pvc() {
  aws_ ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/created-for/pvc/namespace,Values=fcg" \
    --query 'Volumes[].VolumeId' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_broker() {
  aws_ mq list-brokers \
    --query "BrokerSummaries[?starts_with(BrokerName, '${PREFIXO}')].BrokerId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_dominio_busca() {
  aws_ opensearch list-domain-names \
    --query "DomainNames[?starts_with(DomainName,'${PREFIXO}')].DomainName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_tabela_read_model() {
  aws_ dynamodb list-tables \
    --query "TableNames[?@=='${PREFIXO}biblioteca']" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Toda outra tabela com o prefixo e a da funcao: a do read model tem linha propria, e as
# duas nao podem ser contadas duas vezes.
q_tabela_idempotencia() {
  aws_ dynamodb list-tables \
    --query "TableNames[?starts_with(@, '${PREFIXO}') && @!='${PREFIXO}biblioteca']" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Endpoint em remocao ainda aparece por um tempo, e nao cobra mais: so os outros estados
# contam.
q_endpoints() {
  aws_ ec2 describe-vpc-endpoints \
    --filters "Name=tag:Name,Values=${PREFIXO}endpoint-*" \
    --query "VpcEndpoints[?State!='deleted' && State!='Deleted'].VpcEndpointId" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_sgs_lbc() {
  aws_ ec2 describe-security-groups \
    --filters "Name=tag-key,Values=elbv2.k8s.aws/cluster" \
    --query 'SecurityGroups[].GroupId' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_lb_controller() {
  aws_ elbv2 describe-load-balancers \
    --query "LoadBalancers[?starts_with(LoadBalancerName,'k8s-')].LoadBalancerName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# Os alvos pendem do grupo: sem grupo nao ha alvo, e a linha sai limpa. Com a sessao fechada
# o grupo tem de estar vazio -- alvo registrado ali e ip de pod que ja nao existe, sinal de
# que o binding nao saiu antes do cluster.
q_alvos_tg() {
  local tg_arn
  tg_arn="$(q_tg | head -n1)"
  [[ -n "$tg_arn" ]] || return 0

  aws_ elbv2 describe-target-health \
    --target-group-arn "$tg_arn" \
    --query 'TargetHealthDescriptions[].Target.Id' \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_namespace() {
  aws_ servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE}'].Id" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

q_funcao() {
  aws_ lambda list-functions \
    --query "Functions[?starts_with(FunctionName, '${PREFIXO}')].FunctionName" \
    --output text | tr '\t' '\n' | grep -v '^$' || true
}

# O mapeamento pende da funcao: sem funcao nao ha mapeamento, e a linha sai limpa. Com
# funcao viva, as duas linhas acusam -- que e o correto, sao dois recursos cobrados.
q_mapeamento_origem() {
  local fn
  for fn in $(q_funcao); do
    aws_ lambda list-event-source-mappings \
      --function-name "$fn" \
      --query 'EventSourceMappings[].UUID' \
      --output text | tr '\t' '\n' | grep -v '^$' || true
  done
}

# ---------------------------------------------------------------------------
# o inventario declarado
#
# Fonte unica: cada linha e ao mesmo tempo o que se verifica, o que o relatorio nomeia e o
# que a mensagem de erro cita. O rotulo nao e reescrito em lugar nenhum -- acrescentar
# categoria aqui muda a verificacao e o texto juntos, e nao ha como uma mudar sem a outra.
#
# O sentido inverte a comparacao, e nao ha segundo laco para as linhas invertidas:
#   esperado  -> achar e correto, faltar e erro
#   proibido  -> achar e o erro, faltar e correto
# Tratar todas as linhas do mesmo jeito passaria na checagem de sintaxe e mentiria no
# primeiro inventario, dando a sessao por fechada com o broker cobrando.
#
# O campo de quantidade e quantos se espera achar, e nao um minimo: tres roles com o prefixo
# sao tres, e uma quarta seria tao errada quanto nenhuma.
INVENTARIO=(
  "esperado|1|API HTTP|q_api"
  "esperado|1|authorizer JWT|q_authorizer"
  "esperado|1|integracao privada da borda|q_integracao"
  "esperado|1|VPC Link da borda|q_vpc_link"
  "esperado|1|NLB interno|q_nlb"
  "esperado|1|target group do Traefik|q_tg"
  "esperado|1|grupo de log de acesso do gateway|q_log_gateway"
  "esperado|1|segredo da credencial do broker|q_segredo_broker"
  "esperado|3|repositorios de imagem imutaveis|q_repositorios"
  "esperado|1|provedor OIDC do GitHub|q_oidc"
  "esperado|3|roles do CD|q_roles_cd"
  "esperado|3|roles de pod identity|q_roles_pod"
  "proibido|0|cluster EKS|q_cluster"
  "proibido|0|nos do cluster|q_nos"
  "proibido|0|instancia da F3|q_instancia_f3"
  "proibido|0|endereco IP fixo|q_ip_fixo"
  "proibido|0|volumes de PVC do namespace fcg|q_volumes_pvc"
  "proibido|0|broker gerenciado|q_broker"
  "proibido|0|dominio de busca|q_dominio_busca"
  "proibido|0|tabela do read model|q_tabela_read_model"
  "proibido|0|tabela de idempotencia da funcao|q_tabela_idempotencia"
  "proibido|0|endpoints de VPC da sessao|q_endpoints"
  "proibido|0|SGs do LB controller|q_sgs_lbc"
  "proibido|0|LB criado pelo controller|q_lb_controller"
  "proibido|0|alvos registrados no TG|q_alvos_tg"
  "proibido|0|namespace de descoberta da F3|q_namespace"
  "proibido|0|funcao serverless|q_funcao"
  "proibido|0|mapeamento de origem de eventos|q_mapeamento_origem"
)

# ---------------------------------------------------------------------------
# verificacao
# ---------------------------------------------------------------------------

faltando=0
sobrando=0

echo "inventário do satélite em ${REGIAO} (prefixo '${PREFIXO}'):"
echo

for linha in "${INVENTARIO[@]}"; do
  IFS='|' read -r sentido quantidade rotulo consulta <<<"$linha"

  achado="$("$consulta")"
  if [[ -z "$achado" ]]; then
    encontrados=0
  else
    encontrados="$(printf '%s\n' "$achado" | wc -l | tr -d ' ')"
  fi

  case "$sentido" in
    esperado)
      if [[ "$encontrados" -eq "$quantidade" ]]; then
        printf '  ok         %s\n' "$rotulo"
      else
        printf '  AUSENTE    %s (%s de %s)\n' "$rotulo" "$encontrados" "$quantidade"
        faltando=$((faltando + 1))
      fi
      ;;
    proibido)
      if [[ "$encontrados" -eq 0 ]]; then
        printf '  ok         %s: inexistente\n' "$rotulo"
      else
        printf '  EXCEDENTE  %s (%s)\n' "$rotulo" "$encontrados"
        sobrando=$((sobrando + 1))
      fi
      ;;
    *)
      echo "erro: sentido desconhecido '${sentido}' na linha '${rotulo}'." >&2
      exit 2
      ;;
  esac
done

echo

# O excedente decide primeiro: sobrou recurso cobrado por hora e o que custa dinheiro
# enquanto ninguem olha, enquanto peca faltando do permanente so custa uma aplicacao.
if [[ "$sobrando" -gt 0 ]]; then
  echo "falha: sobrou recurso cobrado por hora (${sobrando}); veja as linhas marcadas acima." >&2
  exit 1
fi

if [[ "$faltando" -gt 0 ]]; then
  echo "falha: falta peça do inventário permanente (${faltando}); veja as linhas marcadas acima." >&2
  exit 2
fi

echo "ok: o inventário bate — permanente completo e nada cobrado por hora de pé."
