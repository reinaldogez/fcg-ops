# Endpoints de interface que dao ao servico de integracao caminho para a plataforma
# sem sair da VPC. Moram neste root, e nao no permanente, porque sao cobrados por
# hora: o criterio que define quem vive aqui.
#
# Por que existem: o mapeamento de origem de eventos cria interfaces de rede na
# sub-rede do broker para consumir dele, e essas interfaces precisam alcancar tres
# servicos -- a plataforma de funcoes, o emissor de credencial temporaria e o
# gerenciador de segredos, este ultimo porque a autenticacao do mapeamento e por
# segredo. A sub-rede tem rota para o portao de internet, mas as interfaces do
# mapeamento nascem sem endereco publico, e portao de internet so serve quem tem um.
# Sem estes endpoints o mapeamento fica habilitado e nao consome: o diagnostico vem
# em LastProcessingResult, nunca em erro de apply.
#
# Endpoint de interface nao expoe nada: ele traz o servico para dentro da VPC, com
# endereco privado, e o trafego nao toca a internet. E a mesma tecnologia da
# integracao privada da borda.
locals {
  # a plataforma de funcoes e o emissor de credencial sao exigidos sempre; o
  # gerenciador de segredos so porque o mapeamento autentica no broker por segredo.
  servicos_do_mapeamento = {
    lambda  = "com.amazonaws.${var.aws_region}.lambda"
    sts     = "com.amazonaws.${var.aws_region}.sts"
    secrets = "com.amazonaws.${var.aws_region}.secretsmanager"
  }
}

# grupo proprio, separado do grupo do broker: o que se autoriza aqui e a chegada na
# porta de gerenciamento dos servicos da plataforma, e nao trafego de mensageria.
# manter os dois no mesmo grupo misturaria duas posturas num objeto so.
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}endpoints"
  description = "Postura dos endpoints de interface: chegada em 443 a partir das interfaces do mapeamento."
  vpc_id      = data.aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}endpoints"
  }
}

# a origem autorizada e o grupo do broker, e a razao e medida: o servico de
# integracao coloca as interfaces que ele cria no mesmo grupo do broker que elas
# consomem. autorizar por grupo de origem, e nao por faixa de enderecos, mantem a
# regra valida quando o endereco privado dessas interfaces mudar -- e ele muda a
# cada sessao, porque as interfaces nascem e morrem com o mapeamento.
resource "aws_vpc_security_group_ingress_rule" "endpoints_https" {
  security_group_id = aws_security_group.endpoints.id
  description       = "Chegada dos servicos da plataforma, apenas a partir do grupo do broker."

  referenced_security_group_id = aws_security_group.broker.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# um endpoint por servico, todos na sub-rede do broker: e nela que o mapeamento cria
# as interfaces, e endpoint em outra sub-rede nao seria alcancado. a sub-rede vem da
# mesma consulta que o broker usa, entao as duas coisas nao podem divergir.
#
# o nome privado fica ligado -- e o que faz o nome publico do servico resolver para
# o endereco privado do endpoint. desligado, o nome resolveria para o endereco
# publico e o endpoint nao seria usado: endpoint criado, cobrado, e trafego passando
# por fora. e o modo de falha silencioso desta pagina.
#
# so o perfil com funcao paga os tres endpoints por hora. o grupo e as regras ficam
# sempre, porque nao cobram, e assim o resto do grafo nao muda com o perfil.
resource "aws_vpc_endpoint" "mapeamento" {
  for_each = var.funcao_ligada ? local.servicos_do_mapeamento : {}

  vpc_id            = data.aws_vpc.satelite.id
  service_name      = each.value
  vpc_endpoint_type = "Interface"

  subnet_ids          = data.aws_subnets.broker.ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name_prefix}endpoint-${each.key}"
  }
}
