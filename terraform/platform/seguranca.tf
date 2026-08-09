resource "aws_security_group" "instancia" {
  name        = "${var.name_prefix}instancia"
  description = "Postura de rede do no do cluster: administracao pelo endereco do autor e portas de no so de dentro da VPC."
  vpc_id      = aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}instancia"
  }
}

# uma regra por recurso, e nao blocos embutidos no grupo: regra embutida obriga a
# reescrever o conjunto inteiro a cada mudanca, e o plano nao diz qual regra
# mudou.
resource "aws_vpc_security_group_ingress_rule" "administracao" {
  security_group_id = aws_security_group.instancia.id
  description       = "Acesso administrativo, restrito ao endereco do autor."

  cidr_ipv4   = var.admin_cidr
  ip_protocol = "tcp"
  from_port   = 22
  to_port     = 22
}

# as duas portas de no aceitam somente origem interna. quem chega de fora e o
# gateway, e ele entra pela integracao privada, ja de dentro da VPC. o Grafana e
# as demais interfaces de gerenciamento nao ganham regra nenhuma: o acesso a elas
# e por tunel.
resource "aws_vpc_security_group_ingress_rule" "porta_de_no_users" {
  security_group_id = aws_security_group.instancia.id
  description       = "Porta de no do identity, alcancavel apenas de dentro da VPC."

  cidr_ipv4   = aws_vpc.satelite.cidr_block
  ip_protocol = "tcp"
  from_port   = 30081
  to_port     = 30081
}

resource "aws_vpc_security_group_ingress_rule" "porta_de_no_catalog" {
  security_group_id = aws_security_group.instancia.id
  description       = "Porta de no do catalog, alcancavel apenas de dentro da VPC."

  cidr_ipv4   = aws_vpc.satelite.cidr_block
  ip_protocol = "tcp"
  from_port   = 30083
  to_port     = 30083
}

# saida irrestrita e deliberada, e a restricao de exposicao e sobre entrada: sem
# ela a instancia nao busca o instalador do k3s nem as imagens no registro
# publico, e nao ha NAT nem endpoint de VPC para estreitar esse caminho.
resource "aws_vpc_security_group_egress_rule" "saida" {
  security_group_id = aws_security_group.instancia.id
  description       = "Saida para instalar o k3s e puxar imagens do registro publico."

  cidr_ipv4   = "0.0.0.0/0"
  ip_protocol = "-1"
}
