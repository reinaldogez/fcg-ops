data "aws_iam_policy_document" "instancia_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

# Um bloco por motivo. Cada conjunto de acoes e exatamente o que o componente
# correspondente exerce: nada concedido "por garantia".
data "aws_iam_policy_document" "instancia" {
  statement {
    sid    = "ModeloDeLeitura"
    effect = "Allow"

    # as tres chamadas que o catalog faz, incluindo a reconstrucao do read model,
    # que escreve pela mesma porta e nao apaga nada.
    actions = [
      "dynamodb:PutItem",
      "dynamodb:Query",
      "dynamodb:DescribeTable",
    ]

    # sem /index/*: a tabela nao tem indice secundario.
    resources = [aws_dynamodb_table.biblioteca.arn]
  }

  statement {
    sid       = "CredencialDoBroker"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [aws_secretsmanager_secret.broker.arn]
  }

  statement {
    sid     = "DescobertaDoBroker"
    effect  = "Allow"
    actions = ["mq:DescribeBroker"]

    # padrao de ARN, e nao atributo de recurso, porque o broker vive no root de
    # sessao: ele nasce e morre por sessao e nao existe neste estado.
    resources = ["arn:aws:mq:${var.aws_region}:*:broker:${var.name_prefix}*"]
  }

  statement {
    sid     = "ListagemDeBrokers"
    effect  = "Allow"
    actions = ["mq:ListBrokers"]

    # unico recurso irrestrito da politica: mq:ListBrokers nao aceita escopo de
    # recurso, entao restringi-la a um ARN negaria a chamada inteira.
    resources = ["*"]
  }
}

resource "aws_iam_role" "instancia" {
  name               = "${var.name_prefix}instancia"
  assume_role_policy = data.aws_iam_policy_document.instancia_assume.json
}

resource "aws_iam_role_policy" "instancia" {
  name   = "${var.name_prefix}instancia"
  role   = aws_iam_role.instancia.id
  policy = data.aws_iam_policy_document.instancia.json
}

resource "aws_iam_instance_profile" "instancia" {
  name = "${var.name_prefix}instancia"
  role = aws_iam_role.instancia.name
}
