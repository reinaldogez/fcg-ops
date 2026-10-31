# Postura de rede do broker de sessao. Mora aqui, e nao no root permanente, pelo
# mesmo critério que define quem vive neste root: o grupo nasce e morre com o
# broker que ele protege. No permanente ele sobreviveria a todas as sessoes
# seguintes descrevendo uma porta que nao existe mais.
#
# O grupo e proprio, e nao o dos nos do cluster: reusar o grupo dos nos obrigaria
# a abrir 5671 nele -- porta em que nada escuta nos nos --, o que e postura pior, e
# misturaria a postura do broker com a do cluster.
resource "aws_security_group" "broker" {
  name        = "${var.name_prefix}broker"
  description = "Postura de rede do broker de sessao: porta de transporte apenas para quem publica."
  vpc_id      = data.aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}broker"
  }
}

# as duas autorizacoes referenciam o grupo de origem, e nao uma faixa de
# enderecos: a origem e o grupo dos nos do cluster, por onde os pods saem, e a
# regra sobrevive a troca dos enderecos privados dos nos e dos pods.
#
# duas portas, e as duas de entrada no broker. transporte com TLS e por onde os
# servicos publicam e consomem.
resource "aws_vpc_security_group_ingress_rule" "transporte" {
  security_group_id = aws_security_group.broker.id
  description       = "Porta de transporte com TLS, apenas a partir do grupo do no do cluster."

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
}

# a interface de gerenciamento e entrada no broker, e nao saida dos nos: o servico
# gerenciado publica o management padrao do RabbitMQ em 443 no mesmo endereco, e e
# por ela que o pod efemero de topologia cria as filas no perfil com funcao. sem
# esta regra a criacao da topologia pendura, e o sintoma se confunde com falha de
# rede da VPC.
resource "aws_vpc_security_group_ingress_rule" "gerenciamento" {
  security_group_id = aws_security_group.broker.id
  description       = "Interface de gerenciamento, apenas a partir do grupo do no do cluster."

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# saida, e ela nao e opcional: o servico de integracao cria as interfaces do
# mapeamento dentro deste grupo, e elas precisam originar conexao para os endpoints
# de interface. grupo declarado por recurso nasce sem a saida irrestrita que o
# console adiciona por padrao, entao sem esta regra o mapeamento fica habilitado e
# nao consome -- medido nesta sessao, com os endpoints ja disponiveis.
#
# o destino e o grupo dos endpoints, e nao a internet: a saida que se abre e
# exatamente a que alcanca os tres servicos trazidos para dentro da VPC.
resource "aws_vpc_security_group_egress_rule" "saida_para_endpoints" {
  security_group_id = aws_security_group.broker.id
  description       = "Saida para os endpoints de interface, usada pelas interfaces do mapeamento."

  referenced_security_group_id = aws_security_group.endpoints.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# as interfaces do mapeamento consomem o broker de dentro deste mesmo grupo, e
# trafego entre membros do mesmo grupo nao e liberado implicitamente: precisa de par
# de regras que referencie o proprio grupo. sem elas o mapeamento reporta origem
# inalcancavel com o broker em estado ativo -- medido nesta sessao, e o sintoma nao
# distingue "broker fora do ar" de "regra ausente".
#
# os nos do cluster continuam autorizados pelas regras acima; estas cobrem so o
# consumo pelo mapeamento, que e um caminho interno ao grupo.
resource "aws_vpc_security_group_ingress_rule" "transporte_do_mapeamento" {
  security_group_id = aws_security_group.broker.id
  description       = "Porta de transporte, a partir do proprio grupo: e nele que o mapeamento cria suas interfaces."

  referenced_security_group_id = aws_security_group.broker.id
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
}

resource "aws_vpc_security_group_egress_rule" "saida_para_o_broker" {
  security_group_id = aws_security_group.broker.id
  description       = "Saida na porta de transporte, usada pelas interfaces do mapeamento para alcancar o broker."

  referenced_security_group_id = aws_security_group.broker.id
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
}

# caminho da borda ate o Traefik. o grupo do balanceador nasce no root permanente
# sem saida nenhuma; a saida para os nos e de sessao porque o grupo dos nos so
# existe enquanto o cluster existe. 8000 e o entrypoint web do Traefik.
resource "aws_vpc_security_group_egress_rule" "nlb_para_nos" {
  security_group_id = data.aws_security_group.nlb.id
  description       = "Saida do balanceador da borda para o entrypoint web do Traefik nos nos do cluster."

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# o target group aponta para IP de pod, e os pods saem com o grupo do no: a
# entrada e no grupo dos nos, com origem no grupo do balanceador.
resource "aws_vpc_security_group_ingress_rule" "nos_do_nlb" {
  security_group_id = module.eks.node_security_group_id
  description       = "Chegada do balanceador da borda no entrypoint web do Traefik."

  referenced_security_group_id = data.aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}
