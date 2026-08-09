# a imagem vem do parametro publico mantido pela propria distribuicao: filtro por
# atributo com imagem mais recente escolhe imagem errada em silencio quando o
# filtro esta mal escrito, enquanto um caminho de parametro errado falha na
# leitura.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# so o material publico entra aqui. a chave privada e gerada fora do Terraform e
# nunca chega ao estado.
resource "aws_key_pair" "autor" {
  key_name   = "${var.name_prefix}autor"
  public_key = var.chave_publica_ssh
}

# o endereco fixo e alocado separado da instancia e associado por recurso
# proprio: declara-lo dentro da instancia amarraria o endereco ao ciclo dela, e
# ele precisa sobreviver a parada da maquina entre sessoes.
resource "aws_eip" "cluster" {
  domain = "vpc"

  tags = {
    Name = "${var.name_prefix}ip-fixo"
  }
}

resource "aws_instance" "cluster" {
  ami           = data.aws_ssm_parameter.al2023.value
  instance_type = "m7i-flex.large"

  # so a sub-rede a: a segunda existe para a VPC Link, nao para redundancia de
  # instancia.
  subnet_id              = aws_subnet.publica["a"].id
  vpc_security_group_ids = [aws_security_group.instancia.id]
  key_name               = aws_key_pair.autor.key_name
  iam_instance_profile   = aws_iam_instance_profile.instancia.name

  root_block_device {
    volume_type = "gp3"
    volume_size = 16
  }

  # token obrigatorio fecha o servico de metadados para requisicao sem sessao. o
  # limite de dois saltos existe porque a requisicao que sai de dentro de um pod
  # atravessa a rede do cluster e gasta um salto a mais do que o padrao permite:
  # com o padrao de um, o SDK nao encontra credencial e o sintoma aparece como
  # prontidao do catalog reportando tabela inacessivel, que parece falta de
  # permissao e nao e.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # imagem nova da distribuicao nao pode propor troca da instancia: a maquina
  # guarda o cluster e a configuracao materializada, e substitui-la os apagaria.
  lifecycle {
    ignore_changes = [ami]
  }

  # o dado de inicializacao poe um cluster vazio de pe e nada mais. modo de
  # leitura no arquivo de acesso ao cluster porque a operacao de sessao e manual
  # e exigiria elevacao a cada comando. nenhum segredo, nenhuma configuracao e
  # nenhum workload entram aqui.
  user_data = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
  EOT

  tags = {
    Name = "${var.name_prefix}cluster"
  }
}

resource "aws_eip_association" "cluster" {
  instance_id   = aws_instance.cluster.id
  allocation_id = aws_eip.cluster.id
}
