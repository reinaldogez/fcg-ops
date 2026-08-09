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
