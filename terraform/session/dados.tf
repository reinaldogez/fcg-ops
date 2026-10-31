# tabela do read model da biblioteca. a forma, chave de particao e chave de
# ordenacao textuais, e a que o catalog ja espera, e a politica da role do catalog
# aponta para este nome: mudar um sem o outro quebra a leitura em tempo de
# execucao, nunca no apply.
#
# vive e morre com a sessao porque e derivada dos dados relacionais, que nascem
# vazios a cada sessao. persistir o read model faria ele divergir da fonte da
# verdade.
resource "aws_dynamodb_table" "biblioteca" {
  name         = "${var.name_prefix}biblioteca"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }
}
