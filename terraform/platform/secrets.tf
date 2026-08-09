# A credencial do broker e persistente mesmo com o broker efemero: e o que mantem
# estavel o ARN do segredo entre sessoes, e ele e uma das entradas obrigatorias do
# root da funcao serverless.
resource "random_password" "broker" {
  length = 32

  # alfanumerico puro satisfaz qualquer restricao de formato do provedor sem
  # tentativa e erro.
  special          = false
  override_special = ""
}

resource "aws_secretsmanager_secret" "broker" {
  name = "${var.name_prefix}broker-credencial"

  # janela de recuperacao zerada: a destruicao e limpa, sem nome retido em espera
  # que impeca recriar o segredo com o mesmo nome.
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "broker" {
  secret_id = aws_secretsmanager_secret.broker.id

  # par usuario/senha no formato de autenticacao basica que o mapeamento de origem
  # de eventos consome.
  secret_string = jsonencode({
    username = var.broker_username
    password = random_password.broker.result
  })
}
