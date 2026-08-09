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

variable "admin_cidr" {
  description = "Endereço do autor, em notação CIDR, único autorizado no acesso administrativo da instância. Sem valor padrão de propósito: um padrão permissivo abriria a porta de administração para a internet inteira."
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "O acesso administrativo exige um CIDR de origem específico. Origem irrestrita não é aceita aqui."
  }
}

variable "chave_publica_ssh" {
  description = "Conteúdo da chave pública gerada fora do Terraform. Só o material público entra aqui — o privado nunca chega ao estado."
  type        = string
}
