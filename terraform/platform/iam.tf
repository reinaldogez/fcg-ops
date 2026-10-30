# roles assumidas por conta de servico no cluster, via Pod Identity. a confianca
# e a mesma para todas: quem amarra a role a uma conta de servico e a associacao,
# que nasce com o cluster no root de sessao e nao mora aqui. sem condicao na
# confianca porque a associacao ja e o escopo.
data "aws_iam_policy_document" "confianca_pod_identity" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

# catalog: le e escreve o read model e o indice de busca. um bloco por motivo, e
# cada conjunto de acoes e exatamente o que o servico exerce.
resource "aws_iam_role" "pod_catalog" {
  name               = "${var.name_prefix}pod-catalog"
  assume_role_policy = data.aws_iam_policy_document.confianca_pod_identity.json
}

resource "aws_iam_role_policy" "pod_catalog" {
  name = "${var.name_prefix}pod-catalog"
  role = aws_iam_role.pod_catalog.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # a tabela vive no root de sessao e o ARN pelo nome e previsivel. as tres
        # chamadas sao as que o catalog faz, incluindo a reconstrucao do read
        # model, que escreve pela mesma porta e nao apaga. so a tabela, sem os
        # indices: ela nao tem indice secundario.
        Sid    = "ModeloDeLeitura"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:Query",
          "dynamodb:DescribeTable",
        ]
        Resource = "arn:aws:dynamodb:${var.aws_region}:${data.aws_caller_identity.atual.account_id}:table/${var.name_prefix}biblioteca"
      },
      {
        # o dominio tambem nasce na sessao; o ARN pelo nome cobre o dominio
        # recriado a cada sessao sem reaplicar este root.
        Sid    = "IndiceDeBusca"
        Effect = "Allow"
        Action = [
          "es:ESHttpGet",
          "es:ESHttpHead",
          "es:ESHttpPut",
          "es:ESHttpPost",
          "es:ESHttpDelete",
        ]
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.atual.account_id}:domain/${var.name_prefix}busca/*"
      },
    ]
  })
}

# controlador de balanceadores: a politica publicada pelo projeto, versionada
# aqui sem edicao. editar a copia a afastaria da versao do controlador, e a
# proxima atualizacao teria que reconciliar a diferenca a mao.
resource "aws_iam_policy" "pod_lbc" {
  name   = "${var.name_prefix}pod-lbc"
  policy = file("${path.module}/politicas/lbc-iam-policy-v3.6.0.json")
}

resource "aws_iam_role" "pod_lbc" {
  name               = "${var.name_prefix}pod-lbc"
  assume_role_policy = data.aws_iam_policy_document.confianca_pod_identity.json
}

resource "aws_iam_role_policy_attachment" "pod_lbc" {
  role       = aws_iam_role.pod_lbc.name
  policy_arn = aws_iam_policy.pod_lbc.arn
}

# driver de volumes: a politica gerenciada da propria AWS, que acompanha o driver.
resource "aws_iam_role" "pod_ebs_csi" {
  name               = "${var.name_prefix}pod-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.confianca_pod_identity.json
}

resource "aws_iam_role_policy_attachment" "pod_ebs_csi" {
  role       = aws_iam_role.pod_ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# a role vinculada ao servico de busca, que o primeiro dominio da conta exige.
# mora aqui e nao no root de sessao para nao ser recriada a cada sessao: ela e
# unica por conta, e destrui-la no fechamento disputaria com o dominio ainda em
# remocao.
resource "aws_iam_service_linked_role" "opensearch" {
  aws_service_name = "opensearchservice.amazonaws.com"
}
