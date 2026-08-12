# Postura de rede do broker de sessao. Mora aqui, e nao no root permanente, pelo
# mesmo critério que define quem vive neste root: o grupo nasce e morre com o
# broker que ele protege. No permanente ele sobreviveria a todas as sessoes
# seguintes descrevendo uma porta que nao existe mais.
#
# O grupo e proprio, e nao o da instancia: reusar o grupo do no obrigaria a abrir
# 5671 nele -- porta em que nada escuta na instancia --, o que e postura pior, e
# obrigaria a editar o root permanente por causa de um recurso de sessao.
resource "aws_security_group" "broker" {
  name        = "${var.name_prefix}broker"
  description = "Postura de rede do broker de sessao: porta de transporte apenas para quem publica."
  vpc_id      = data.aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}broker"
  }
}

# a instancia do cluster e a origem autorizada, encontrada pelo nome como a rede e
# o segredo. o acoplamento entre os dois roots continua sendo a etiqueta de nome,
# e nao a leitura do estado do outro.
data "aws_security_group" "instancia" {
  name   = "${var.name_prefix}instancia"
  vpc_id = data.aws_vpc.satelite.id
}

# as duas autorizacoes referenciam o grupo de origem, e nao uma faixa de
# enderecos: quem alcanca o broker e exatamente quem esta no grupo do no do
# cluster, e a regra sobrevive a troca do endereco privado da instancia.
#
# duas portas, e as duas de entrada no broker. transporte com TLS e por onde os
# servicos publicam e consomem.
resource "aws_vpc_security_group_ingress_rule" "transporte" {
  security_group_id = aws_security_group.broker.id
  description       = "Porta de transporte com TLS, apenas a partir do grupo do no do cluster."

  referenced_security_group_id = data.aws_security_group.instancia.id
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
}

# a interface de gerenciamento e entrada no broker, e nao saida da instancia: o
# servico gerenciado publica o management padrao do RabbitMQ em 443 no mesmo
# endereco, e e por ela que a topologia e criada. sem esta regra o script de
# topologia pendura, e o sintoma se confunde com falha de rede da VPC.
resource "aws_vpc_security_group_ingress_rule" "gerenciamento" {
  security_group_id = aws_security_group.broker.id
  description       = "Interface de gerenciamento, apenas a partir do grupo do no do cluster."

  referenced_security_group_id = data.aws_security_group.instancia.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}
