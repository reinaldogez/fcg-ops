# o que este root usa do root permanente e encontrado aqui, por nome. o acoplamento
# entre os dois roots e o nome, e nao o estado do outro: a dependencia e de mao
# unica, e tudo o que se le aqui existe enquanto o permanente existir.

# um so no root: a conta entra no ARN de recurso da politica de acesso da busca.
data "aws_caller_identity" "atual" {}

# as duas sub-redes da plataforma. o plano de controle exige duas zonas; os nos, o
# broker e a busca usam so a da zona a.
data "aws_subnet" "publica" {
  for_each = toset(["a", "b"])

  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.satelite.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}subrede-${each.key}"]
  }
}

# o grupo do balanceador interno da borda. ele nasce no permanente sem saida
# nenhuma, e a saida para os nos e aberta neste root.
data "aws_security_group" "nlb" {
  name   = "${var.name_prefix}nlb"
  vpc_id = data.aws_vpc.satelite.id
}

# roles das identidades de pod, associadas neste root aos service accounts.
data "aws_iam_role" "pod" {
  for_each = toset(["catalog", "lbc", "ebs-csi"])

  name = "${var.name_prefix}pod-${each.key}"
}

# roles do pipeline de entrega, que ganham acesso ao cluster por access entry.
data "aws_iam_role" "cd" {
  for_each = toset(["identity", "catalog", "payments"])

  name = "${var.name_prefix}cd-${each.key}"
}
