variable "aws_region" {
  description = "Região onde os recursos do satélite são criados."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefixo de todo nome de recurso do satélite. É o que torna possível casar o broker efêmero por padrão de ARN, sem conhecer o nome exato."
  type        = string
  default     = "fcg-"
}

variable "broker_username" {
  description = "Usuário do broker gerenciado, gravado no segredo junto da senha gerada. A senha nunca vem daqui."
  type        = string
  default     = "fcg"
}

variable "authorizer_ligado" {
  description = "Interruptor da autenticação de borda. Desligado só na fase 1 de uma conta nova, quando o discovery ainda não tem quem o sirva, e no plan -destroy final da borda; o padrão verdadeiro é o estado estável, e é o que dispensa lembrar de religar a autenticação depois."
  type        = bool
  default     = true
}

variable "verificar_discovery" {
  description = "Liga a leitura do documento de descoberta do identity. Só na fase 2 de uma conta nova, enquanto o authorizer ainda não existe; em qualquer outro plan a leitura falharia com o cluster desligado."
  type        = bool
  default     = false
}
