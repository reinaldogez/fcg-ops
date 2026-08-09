# Read model da biblioteca. A forma da tabela nao e escolha aberta: e o que o
# catalog ja espera. Chave de particao PK e chave de ordenacao SK, ambas string,
# sem validade de item e sem indice secundario. Divergir daqui faz a verificacao
# de prontidao do catalog falhar na primeira sessao.
resource "aws_dynamodb_table" "biblioteca" {
  name = "${var.name_prefix}biblioteca"

  # cobranca sob demanda: a tabela e permanente e nao cobra parada.
  billing_mode = "PAY_PER_REQUEST"

  hash_key  = "PK"
  range_key = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }
}
