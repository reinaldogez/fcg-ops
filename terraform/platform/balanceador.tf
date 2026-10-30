# balanceador interno da borda: o VPC Link entrega no listener, e o listener no
# grupo de alvos que o cluster preenche com os ips dos pods do controlador de
# entrada. fica no root permanente porque o VPC Link e a integracao apontam para
# ele, e recria-los a cada sessao mudaria a borda inteira.

resource "aws_security_group" "vpc_link" {
  name        = "${var.name_prefix}vpc-link"
  description = "Interfaces do VPC Link da borda: so saem para o balanceador interno."
  vpc_id      = aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}vpc-link"
  }
}

resource "aws_security_group" "nlb" {
  name        = "${var.name_prefix}nlb"
  description = "Balanceador interno da borda: so aceita o VPC Link."
  vpc_id      = aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}nlb"
  }
}

# uma regra por recurso, e nao blocos embutidos no grupo: regra embutida obriga a
# reescrever o conjunto inteiro a cada mudanca, e o plano nao diz qual regra
# mudou.
resource "aws_vpc_security_group_egress_rule" "vpc_link_para_nlb" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Saida do VPC Link para o listener do balanceador interno."

  referenced_security_group_id = aws_security_group.nlb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "nlb_do_vpc_link" {
  security_group_id = aws_security_group.nlb.id
  description       = "Entrada no listener vinda so do VPC Link."

  referenced_security_group_id = aws_security_group.vpc_link.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

# a regra do balanceador para os nos (8000) e a entrada correspondente no grupo
# de seguranca dos nos nao moram aqui: esse grupo nasce no root de sessao, e a
# dependencia e de mao unica -- a sessao le este root, nunca o contrario.

resource "aws_lb" "borda" {
  name               = "${var.name_prefix}nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = [for s in aws_subnet.publica : s.id]
  security_groups    = [aws_security_group.nlb.id]

  # os nos ficam so na zona a; o no do balanceador na zona b precisa encaminhar
  # para la, e sem balanceamento entre zonas ele so enxergaria alvos da propria.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "traefik" {
  name        = "${var.name_prefix}traefik"
  target_type = "ip"
  protocol    = "TCP"
  port        = 8000
  vpc_id      = aws_vpc.satelite.id

  # os 300 s padrao deixariam o ip antigo drenando 5 min no rollout do
  # controlador de entrada e no fechamento da sessao.
  deregistration_delay = 30

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
  }
}

resource "aws_lb_listener" "borda" {
  load_balancer_arn = aws_lb.borda.arn
  protocol          = "TCP"
  port              = 80

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.traefik.arn
  }
}
