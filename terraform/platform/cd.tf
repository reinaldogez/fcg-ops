# a conta resolvida em tempo de plano, e nunca literal: os ARNs previsiveis deste
# root (cluster, tabela, dominio de busca) sao montados a partir dela.
data "aws_caller_identity" "atual" {}

# o provedor que deixa o runner do GitHub trocar o token da execucao por uma
# credencial temporaria: nenhuma chave de acesso de longa duracao vive no
# repositorio de servico.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

# o sub e o literal que o GitHub emite para cada repositorio, lido em
# actions/oidc/customization/sub de cada um. em repositorio novo o GitHub emite o
# formato imutavel repo:<owner>@<id>/<repo>@<id>:ref:..., e o formato documentado
# falha em silencio: o runner so ve AccessDenied, e a causa so aparece no
# CloudTrail.
locals {
  servicos_cd = {
    identity = {
      repositorio = "fcg-identity"
      sub         = "repo:reinaldogez/fcg-identity:ref:refs/heads/main"
    }
    catalog = {
      repositorio = "fcg-catalog"
      sub         = "repo:reinaldogez/fcg-catalog:ref:refs/heads/main"
    }
    payments = {
      repositorio = "fcg-payments"
      sub         = "repo:reinaldogez/fcg-payments:ref:refs/heads/main"
    }
  }
}

# uma role por servico, e cada uma so aceita o token do ramo principal do proprio
# repositorio: um pipeline nao publica imagem de outro servico, e ramo de
# trabalho nao publica nada.
resource "aws_iam_role" "cd" {
  for_each = local.servicos_cd

  name = "${var.name_prefix}cd-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
        Action    = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
            "token.actions.githubusercontent.com:sub" = each.value.sub
          }
        }
      },
    ]
  })
}

# o acesso ao cluster (entrada de acesso e RBAC) nao mora aqui: o cluster nasce
# no root de sessao, e a permissao dentro dele vai junto.
resource "aws_iam_role_policy" "cd" {
  for_each = local.servicos_cd

  name = "${var.name_prefix}cd-${each.key}"
  role = aws_iam_role.cd[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # unico recurso irrestrito da politica: a acao nao aceita escopo de
        # recurso, entao restringi-la a um ARN negaria a chamada inteira.
        Sid      = "TokenDoRegistro"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "PublicacaoNoProprioRepositorio"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:DescribeImages",
        ]
        Resource = aws_ecr_repository.servico[each.key].arn
      },
      {
        # o ARN e previsivel com o cluster desligado, e e isso que faz a guarda
        # do pipeline receber ResourceNotFoundException em vez de AccessDenied:
        # cluster ausente e permissao negada viram respostas distintas.
        Sid      = "DescobertaDoCluster"
        Effect   = "Allow"
        Action   = ["eks:DescribeCluster"]
        Resource = "arn:aws:eks:${var.aws_region}:${data.aws_caller_identity.atual.account_id}:cluster/${var.name_prefix}eks"
      },
    ]
  })
}
