# dominio de busca do catalogo. o indice e derivado, como o read model, e vive na
# sessao: o dominio nao pode ser desligado e religado, so apagado, entao fora da
# sessao ele so cobraria.
#
# a service-linked role do servico nao e declarada aqui: ela mora no root
# permanente, e apagar o dominio nao a apaga.

# grupo proprio, com entrada so dos nos do cluster: e de la que o catalog fala com
# a busca.
resource "aws_security_group" "busca" {
  name        = "${var.name_prefix}busca"
  description = "Postura de rede do dominio de busca: HTTPS apenas a partir dos nos do cluster."
  vpc_id      = data.aws_vpc.satelite.id

  tags = {
    Name = "${var.name_prefix}busca"
  }
}

resource "aws_vpc_security_group_ingress_rule" "busca_dos_nos" {
  security_group_id = aws_security_group.busca.id
  description       = "HTTPS a partir do grupo dos nos do cluster."

  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_opensearch_domain" "busca" {
  domain_name    = "${var.name_prefix}busca"
  engine_version = "OpenSearch_3.7"

  # um no, sem zone awareness: o indice e reconstruido a partir da fonte da
  # verdade, entao redundancia so dobraria o custo da sessao.
  cluster_config {
    instance_type          = "t3.small.search"
    instance_count         = 1
    zone_awareness_enabled = false
  }

  ebs_options {
    ebs_enabled = true
    volume_type = "gp3"
    volume_size = 10
  }

  # na sub-rede da zona a, junto dos nos e do broker.
  vpc_options {
    subnet_ids         = [data.aws_subnet.publica["a"].id]
    security_group_ids = [aws_security_group.busca.id]
  }

  domain_endpoint_options {
    enforce_https       = true
    tls_security_policy = "Policy-Min-TLS-1-2-2019-07"
  }

  # a autenticacao e a identidade de workload do catalog, por assinatura SigV4, sem
  # usuario mestre: o principal e so a role do catalog, e nenhum outro pod da
  # sessao alcanca o indice.
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = data.aws_iam_role.pod["catalog"].arn }
      Action    = "es:ESHttp*"
      Resource  = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.atual.account_id}:domain/${var.name_prefix}busca/*"
    }]
  })
}
