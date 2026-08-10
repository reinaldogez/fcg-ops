#!/usr/bin/env bash
set -euo pipefail

# Confere o inventario do satelite na conta: o que tem de estar de pe continua de pe, e o
# que e cobrado por hora nao sobrou ligado. Roda na abertura e no fechamento de toda sessao
# de nuvem, e e a prova do fechamento -- parar a instancia e destruir o root de sessao sao
# intencao; este comando e o que confirma.
#
# So le. Nao cria, nao altera e nao remove recurso nenhum: achar excedente e motivo de
# relatorio e codigo de saida, nunca de limpeza automatica. A decisao de destruir e humana
# e mora no root correspondente.
#
# Codigos de saida: 0 quando o inventario bate; 1 quando sobrou algo cobrado por hora;
# 2 quando falta peca do permanente. Sao dois codigos porque as duas falhas pedem acoes
# opostas -- uma manda destruir, a outra manda aplicar.

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
aws_() {
  aws --region "$REGIAO" "$@"
}

# ---------------------------------------------------------------------------
# consultas
#
# Cada funcao imprime uma linha por recurso encontrado, e nada quando nao encontra. O laco
# de verificacao so conta linhas: quem sabe qual chamada faz o que e a tabela, nao o laco.
#
# Toda consulta termina em '|| true'. Sob 'set -e' a chamada que nao acha nada -- ou que
# falha por permissao -- derrubaria o script no meio do inventario, e o relatorio sairia
# pela metade parecendo sucesso parcial.
# ---------------------------------------------------------------------------

# A instancia e casada por etiqueta de nome e filtrada pelo estado esperado na propria
# consulta: instancia rodando nao conta como encontrada, e cai como ausencia do permanente
# em vez de passar despercebida. Terminada tambem nao conta -- o volume iria junto.
q_instancia_parada() {
  aws_ ec2 describe-instances \
    --filters "Name=tag:Name,Values=${PREFIXO}cluster" \
    "Name=instance-state-name,Values=stopped" \
    --query 'Reservations[].Instances[].InstanceId' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# O que interessa no endereco fixo e estar associado: um endereco alocado e solto cobra por
# hora, entao a consulta exige o campo de associacao preenchido.
q_ip_fixo_associado() {
  aws_ ec2 describe-addresses \
    --filters "Name=tag:Name,Values=${PREFIXO}ip-fixo" \
    --query 'Addresses[?AssociationId!=null].AllocationId' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

q_api() {
  aws_ apigatewayv2 get-apis \
    --query "Items[?Name=='${PREFIXO}api'].ApiId" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
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
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

q_vpc_link() {
  aws_ apigatewayv2 get-vpc-links \
    --query "Items[?Name=='${PREFIXO}vpc-link'].VpcLinkId" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

q_namespace() {
  aws_ servicediscovery list-namespaces \
    --query "Namespaces[?Name=='${NAMESPACE}'].Id" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# Os dois servicos de descoberta: 'users' e 'catalog'. Pagamentos nao tem registro aqui, do
# mesmo modo que nao tem rota -- e a ausencia dele nao e excedente nem falta.
q_servicos_descoberta() {
  local ns_id
  ns_id="$(q_namespace | head -n1)"
  [[ -n "$ns_id" ]] || return 0

  aws_ servicediscovery list-services \
    --filters "Name=NAMESPACE_ID,Values=${ns_id},Condition=EQ" \
    --query "Services[?Name=='users' || Name=='catalog'].Id" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# Camada separada da anterior de proposito: o registro no Cloud Map sao dois recursos por
# servico -- o nome no namespace e a instancia que carrega endereco e porta. Contar so os
# servicos reportaria a borda saudavel com as registracoes ausentes, e o sintoma seria 503
# no gateway com o cluster de pe.
q_registros_descoberta() {
  local svc_id
  for svc_id in $(q_servicos_descoberta); do
    aws_ servicediscovery list-instances \
      --service-id "$svc_id" \
      --query 'Instances[].Id' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
  done
}

q_tabela_read_model() {
  aws_ dynamodb list-tables \
    --query "TableNames[?@=='${PREFIXO}biblioteca']" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

q_segredo_broker() {
  aws_ secretsmanager list-secrets \
    --query "SecretList[?Name=='${PREFIXO}broker-credencial'].ARN" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# A retencao entra na consulta, e nao numa checagem a parte: grupo de log sem validade
# acumula para sempre e cobra armazenamento, entao um grupo com retencao errada nao e o
# recurso esperado -- e outra coisa com o mesmo nome.
q_log_gateway() {
  aws_ logs describe-log-groups \
    --log-group-name-prefix "/aws/apigateway/${PREFIXO}api" \
    --query "logGroups[?retentionInDays==\`${RETENCAO_ESPERADA}\`].logGroupName" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# ---------------------------------------------------------------------------
# consultas do que nao pode existir
#
# A listagem de brokers nao aceita escopo de recurso, entao o filtro pelo prefixo e aqui.
# Funcao e mapeamento de origem nascem no repositorio da funcao, fora deste: eles sao
# procurados pelo prefixo de nome, e nao pela etiqueta de projeto, justamente porque nao ha
# garantia de que o outro repositorio a aplique -- um inventario que so olhasse etiqueta
# diria "limpo" com a funcao ligada.
# ---------------------------------------------------------------------------

q_broker() {
  aws_ mq list-brokers \
    --query "BrokerSummaries[?starts_with(BrokerName, '${PREFIXO}')].BrokerId" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

q_funcao() {
  aws_ lambda list-functions \
    --query "Functions[?starts_with(FunctionName, '${PREFIXO}')].FunctionName" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
}

# O mapeamento pende da funcao: sem funcao nao ha mapeamento, e a linha sai limpa. Com
# funcao viva, as duas linhas acusam -- que e o correto, sao dois recursos cobrados.
q_mapeamento_origem() {
  local fn
  for fn in $(q_funcao); do
    aws_ lambda list-event-source-mappings \
      --function-name "$fn" \
      --query 'EventSourceMappings[].UUID' \
      --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
  done
}

# A tabela de idempotencia da funcao, distinta da tabela do read model: aquela e permanente
# e esperada, esta so existe enquanto a funcao existe.
q_tabela_idempotencia() {
  aws_ dynamodb list-tables \
    --query "TableNames[?starts_with(@, '${PREFIXO}') && @!='${PREFIXO}biblioteca']" \
    --output text 2>/dev/null | tr '\t' '\n' | grep -v '^$' || true
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
# O campo de quantidade e quantos se espera achar, e nao um minimo: dois servicos de
# descoberta sao dois, e um terceiro seria tao errado quanto nenhum.
INVENTARIO=(
  "esperado|1|instancia do cluster, parada, com volume|q_instancia_parada"
  "esperado|1|endereco IP fixo, associado|q_ip_fixo_associado"
  "esperado|1|API HTTP|q_api"
  "esperado|1|authorizer JWT|q_authorizer"
  "esperado|1|VPC Link|q_vpc_link"
  "esperado|1|namespace de descoberta|q_namespace"
  "esperado|2|servicos de descoberta|q_servicos_descoberta"
  "esperado|2|registros de descoberta|q_registros_descoberta"
  "esperado|1|tabela do read model|q_tabela_read_model"
  "esperado|1|segredo da credencial do broker|q_segredo_broker"
  "esperado|1|grupo de log de acesso do gateway|q_log_gateway"
  "proibido|0|broker gerenciado|q_broker"
  "proibido|0|mapeamento de origem de eventos|q_mapeamento_origem"
  "proibido|0|funcao serverless|q_funcao"
  "proibido|0|tabela de idempotencia da funcao|q_tabela_idempotencia"
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
