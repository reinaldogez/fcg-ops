# a rede vem do root permanente por consulta, e nunca por leitura do estado dele:
# a dependencia e de mao unica, e o acoplamento entre os dois roots e a etiqueta
# de nome.
data "aws_vpc" "satelite" {
  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}vpc"]
  }
}

# broker de no unico ocupa exatamente uma sub-rede, entao a consulta casa a sub-rede
# de uma zona pelo nome, e nao o conjunto das duas. o conjunto passaria na
# validacao, porque o argumento e um conjunto de textos, e seria recusado so no
# apply -- onze minutos e meio depois, no pior lugar para descobrir isso.
data "aws_subnets" "broker" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.satelite.id]
  }

  filter {
    name   = "tag:Name"
    values = ["${var.name_prefix}subrede-a"]
  }
}

# o segredo e procurado pelo nome, e nao pelo identificador: o sufixo do ARN e
# aleatorio e muda a cada recriacao, enquanto o nome sobrevive as sessoes.
data "aws_secretsmanager_secret" "broker" {
  name = "${var.name_prefix}broker-credencial"
}

data "aws_secretsmanager_secret_version" "broker" {
  secret_id = data.aws_secretsmanager_secret.broker.id
}

# o par usuario/senha e decodificado uma vez so, para que a senha tenha um unico
# ponto de referencia no root: o bloco de usuario do broker.
locals {
  credencial_broker = jsondecode(data.aws_secretsmanager_secret_version.broker.secret_string)
}

resource "aws_mq_broker" "sessao" {
  # o nome e estavel entre sessoes de proposito: e entrada obrigatoria do root da
  # funcao serverless e a chave da descoberta pelo script de sessao.
  broker_name = "${var.name_prefix}broker"

  engine_type        = "RabbitMQ"
  engine_version     = var.broker_engine_version
  host_instance_type = "mq.m7g.medium"
  deployment_mode    = "SINGLE_INSTANCE"

  # sem endereco publico: quem publica sao os pods do cluster, na mesma VPC, e o
  # mapeamento de origem de eventos alcanca o broker pelas interfaces de rede da
  # propria VPC.
  publicly_accessible = false
  subnet_ids          = data.aws_subnets.broker.ids

  # com grupo de seguranca proprio, declarado no seguranca.tf deste root. broker
  # privado de no unico exige pelo menos um grupo, e omitir o argumento nao
  # deixa o broker sem postura: faz a plataforma escolher o grupo default da VPC,
  # que autoriza entrada apenas a partir de si mesmo. como os nos do cluster
  # estao em outro grupo, o default recusaria justamente quem precisa publicar.
  #
  # o argumento e opcional e nao e calculado no esquema do provedor, entao a
  # escolha feita pela plataforma nunca voltaria para o estado: a omissao seria
  # invisivel no plano e no estado, e apareceria so como conexao recusada.
  security_groups = [aws_security_group.broker.id]
  #
  # sem bloco de registros: o grupo de log nao pertence a este recurso e sobrevive
  # a destruicao dele, entao acumularia um por sessao e o gate de inventario, que
  # exige o broker inexistente entre sessoes, acusaria excedente todas as vezes.
  #
  # sem aplicacao imediata: o argumento so governa modificacao de broker vivo, e
  # este nasce e morre por sessao, sem alteracao no meio.

  # a versao fixada e piso, e nao congelamento: a subida de versao menor acontece
  # na janela de manutencao.
  auto_minor_version_upgrade = true

  # unico ponto do root que referencia a senha. ela entra aqui e nao sai por
  # output nenhum.
  user {
    username = local.credencial_broker.username
    password = local.credencial_broker.password
  }
}
