# um repositorio por servico com imagem propria. a funcao serverless nao entra:
# ela e empacotada e publicada pelo repositorio dela.
locals {
  servicos_ecr = toset(["identity", "catalog", "payments"])
}

resource "aws_ecr_repository" "servico" {
  for_each = local.servicos_ecr

  name = "${var.name_prefix}${each.key}"

  # tag imutavel: a tag que o cluster roda e a mesma imagem que o pipeline
  # publicou, e um push repetido com a mesma tag falha em vez de troca-la calado.
  image_tag_mutability = "IMMUTABLE"

  # um destroy acidental do platform nao leva o historico de imagens: com
  # imagem dentro, a remocao do repositorio falha.
  force_delete = false

  # o scan e o Trivy no pipeline, antes do push; repeti-lo aqui so duplicaria o
  # resultado.
  image_scanning_configuration {
    scan_on_push = false
  }

  encryption_configuration {
    encryption_type = "AES256"
  }
}

# a imagem sem tag e camada orfa de push substituido e nao serve a nada depois
# de um dia; das com tag ficam as dez mais recentes, que cobrem qualquer
# reversao plausivel sem armazenamento crescendo para sempre.
resource "aws_ecr_lifecycle_policy" "servico" {
  for_each = aws_ecr_repository.servico

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "sem tag expira em 1 dia"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "mantem as 10 mais recentes com tag"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*"]
          countType      = "imageCountMoreThan"
          countNumber    = 10
        }
        action = { type = "expire" }
      },
    ]
  })
}
