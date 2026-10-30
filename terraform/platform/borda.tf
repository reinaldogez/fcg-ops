resource "aws_apigatewayv2_api" "fcg" {
  name          = "${var.name_prefix}api"
  description   = "Unica porta de entrada do sistema. Nao ha caminho de rede da internet ate os servicos fora daqui."
  protocol_type = "HTTP"
}

# Issuer circular: a URL de invocacao da propria API e o iss que o identity emite,
# que este authorizer exige e que os servicos validam. Montado aqui a partir do
# identificador da API -- nao e valor de entrada nem string fixa.
#
# Sem sufixo de stage, e e por isso que o stage tem que ser o padrao. Um stage
# nomeado empurraria o discovery para um caminho prefixado enquanto o iss do token
# continuaria sem prefixo.
#
# A criacao do authorizer chama o /.well-known/openid-configuration deste issuer
# e falha com 400 se ele nao responder. Como quem serve esse documento e o
# identity atras da rota aberta, a plataforma nasce em duas fases: ver as
# variaveis authorizer_ligado e verificar_discovery.
locals {
  api_issuer = "https://${aws_apigatewayv2_api.fcg.id}.execute-api.${var.aws_region}.amazonaws.com"
}

# A criacao do authorizer busca este documento e aborta o apply com 400 se ele nao
# responder. Aqui o motivo aparece antes, em vez de a falha chegar como erro de
# requisicao invalida com o apply pela metade.
#
# Bloco de verificacao, e nao pre-condicao: pre-condicao reprova o plano inteiro
# enquanto o discovery nao responder, e ha aplicacao legitima nesse estado --
# qualquer mudanca da borda entre as duas fases e exatamente isso. Aviso informa
# sem impedir.
#
# O segundo assert compara o emissor anunciado com o que o authorizer vai exigir:
# a divergencia nao quebra apply nenhum, ela aparece como 401 com token valido em
# toda rota protegida, e so em runtime.
#
# A leitura fica fora do bloco de verificacao de proposito. Declarada dentro, ela
# vira leitura adiantada para o apply e o plano nunca mais converge: sai sempre
# "will be read during apply", e o codigo de saida detalhado passa a 2 mesmo sem
# mudanca alguma. Fora, e lida no proprio plano e a convergencia se mantem.
#
# A leitura tem interruptor proprio, separado do authorizer: com o authorizer de
# pe o discovery ja foi provado, e le-lo em todo plano faria o plano falhar com o
# cluster desligado, que e o estado normal entre sessoes. So a fase 2 de uma conta
# nova liga a leitura.
#
# O try cobre o interruptor desligado: a lista fica vazia, o indice falha, e o
# valor de reserva faz os dois assert passarem calados.
data "http" "openid" {
  count = var.verificar_discovery ? 1 : 0
  url   = "${local.api_issuer}/.well-known/openid-configuration"
}

check "discovery_do_identity" {
  assert {
    condition     = try(data.http.openid[0].status_code, 200) == 200
    error_message = "O documento de descoberta não respondeu 200 (status ${try(data.http.openid[0].status_code, 0)}). O authorizer não nasce assim: suba o cluster com o identity de pé antes de aplicar com -var verificar_discovery=true."
  }

  assert {
    condition     = try(jsondecode(data.http.openid[0].response_body).issuer, local.api_issuer) == local.api_issuer
    error_message = "O emissor anunciado pela descoberta difere do que o authorizer vai exigir. Esperado ${local.api_issuer}; recebido '${try(jsondecode(data.http.openid[0].response_body).issuer, "corpo não-JSON")}'. Barra final é a divergência mais comum, e ela produz 401 com token válido em toda rota protegida."
  }
}

# A primeira fase do bootstrap nao cria authorizer nenhum. Nao ha depends_on para
# a rota de discovery: o grafo do Terraform e granular por recurso, e nao por
# elemento, entao qualquer aresta daqui de volta para as rotas fecha ciclo com as
# protegidas, que referenciam este recurso. Quem ordena as duas coisas e a
# sequencia das duas aplicacoes, nao o grafo.
resource "aws_apigatewayv2_authorizer" "jwt" {
  count = var.authorizer_ligado ? 1 : 0

  api_id           = aws_apigatewayv2_api.fcg.id
  name             = "${var.name_prefix}jwt"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    # a lista de audiencia e obrigatoria: authorizer sem ela e recusado na
    # criacao, e com ela divergente do token o resultado e 401 com token valido.
    audience = ["fcg"]
    issuer   = local.api_issuer
  }
}

# As duas sub-redes: e por isto que a rede declara duas em zonas distintas. O
# grupo de seguranca e proprio do link, e so sai para o balanceador interno.
#
# Endereco novo de proposito, e nao o do link anterior: substituir no mesmo
# endereco encadearia a destruicao do link com as rotas ainda apontando para as
# integracoes antigas, e o apply morreria no meio.
resource "aws_apigatewayv2_vpc_link" "borda" {
  name               = "${var.name_prefix}vpc-link-borda"
  subnet_ids         = [for s in aws_subnet.publica : s.id]
  security_group_ids = [aws_security_group.vpc_link.id]

  tags = {
    Name = "${var.name_prefix}vpc-link-borda"
  }
}

# Uma integracao so, para o listener do balanceador interno. O gateway nao sabe
# qual servico atende qual caminho: entrega tudo ao controlador de entrada do
# cluster, que despacha por prefixo.
resource "aws_apigatewayv2_integration" "borda" {
  api_id             = aws_apigatewayv2_api.fcg.id
  integration_type   = "HTTP_PROXY"
  integration_method = "ANY"
  integration_uri    = aws_lb_listener.borda.arn

  connection_type = "VPC_LINK"
  connection_id   = aws_apigatewayv2_vpc_link.borda.id

  payload_format_version = "1.0"
}

# As onze rotas, exatamente estas. Tres abertas e oito com authorizer.
#
# A tabela e politica: diz se a rota existe e se exige JWT, e nada alem. Quem
# despacha cada prefixo para o Service certo e o Ingress no cluster. Divergencia
# entre as duas falha fechado: rota sem prefixo no Ingress chega ao controlador e
# volta 404; prefixo no Ingress sem rota aqui e inalcancavel de fora.
#
# Cada aparente anomalia da tabela e deliberada:
#
# - as tres primeiras sao abertas porque sem elas ninguem obtem token, cria conta
#   nem valida assinatura -- fecha-las tornaria o sistema inacessivel por
#   construcao;
# - POST /api/usuarios e aberta e GET /api/usuarios e protegida no mesmo caminho
#   porque o registro e anonimo e a listagem e administrativa: aqui o metodo e o
#   que separa aberto de protegido;
# - os pares nu/guloso (jogos e pedidos) existem porque o segmento guloso nao casa
#   o caminho nu: sem as duas chaves, a colecao ficaria sem rota.
#
# Sem rota padrao de captura: caminho nao declarado morre no gateway com 404, sem
# tocar backend. Sem rota de saude: chave de rota e unica, os dois servicos usam o
# mesmo caminho, e a verificacao de prontidao publica os nomes das dependencias.
locals {
  rotas = {
    "POST /api/auth/{proxy+}"      = { autorizada = false }
    "POST /api/usuarios"           = { autorizada = false }
    "GET /.well-known/{proxy+}"    = { autorizada = false }
    "GET /api/usuarios"            = { autorizada = true }
    "ANY /api/usuarios/{proxy+}"   = { autorizada = true }
    "ANY /api/admin/{proxy+}"      = { autorizada = true }
    "ANY /api/jogos"               = { autorizada = true }
    "ANY /api/jogos/{proxy+}"      = { autorizada = true }
    "ANY /api/pedidos"             = { autorizada = true }
    "ANY /api/pedidos/{proxy+}"    = { autorizada = true }
    "ANY /api/biblioteca/{proxy+}" = { autorizada = true }
  }
}

# O filtro deixa passar toda rota aberta sempre, e as protegidas so quando ha
# authorizer para elas apontarem. Na primeira fase sobram as tres abertas -- entre
# elas a do discovery, que e justamente o que precisa responder para a segunda
# fase poder criar o authorizer.
resource "aws_apigatewayv2_route" "fcg" {
  for_each = { for k, v in local.rotas : k => v if !v.autorizada || var.authorizer_ligado }

  api_id    = aws_apigatewayv2_api.fcg.id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.borda.id}"

  authorization_type = each.value.autorizada ? "JWT" : "NONE"
  authorizer_id      = each.value.autorizada ? aws_apigatewayv2_authorizer.jwt[0].id : null
}

resource "aws_cloudwatch_log_group" "acesso_gateway" {
  name              = "/aws/apigateway/${var.name_prefix}api"
  retention_in_days = 14
}

# Stage padrao, e nao nomeado: e o que faz a URL de invocacao nao ter sufixo, e a
# URL sem sufixo e o issuer circular declarado acima.
resource "aws_apigatewayv2_stage" "padrao" {
  api_id      = aws_apigatewayv2_api.fcg.id
  name        = "$default"
  auto_deploy = true

  # o throttle vale desde a primeira aplicacao: e a resposta a exposicao de um
  # gateway publico e permanente, e nao um ajuste posterior.
  default_route_settings {
    throttling_rate_limit  = 10
    throttling_burst_limit = 20
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.acesso_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}
