terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }

    # gera a senha do broker; a senha vive no estado, que e local e nao versionado.
    random = {
      source  = "hashicorp/random"
      version = ">= 3.0"
    }
  }

  # sem bloco backend: o estado fica local e fora do versionamento. o root de
  # sessao guarda a senha do broker em texto plano, e um estado remoto a exporia.
}

provider "aws" {
  region = var.aws_region

  # a etiqueta de projeto em todo recurso e o que torna o inventario posterior
  # possivel sem enumerar tipo por tipo.
  default_tags {
    tags = {
      projeto = "fcg"
    }
  }
}
