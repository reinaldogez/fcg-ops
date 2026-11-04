variable "aws_region" {
  description = "Região onde os recursos de sessão são criados."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefixo de nomes do satélite, o mesmo do root permanente. É por ele que este root encontra a rede e o segredo criados lá, sem ler o estado do outro."
  type        = string
  default     = "fcg-"
}

variable "broker_engine_version" {
  description = "Versão do motor do broker. O provedor exige o valor, e fixá-lo mantém a paridade com a versão usada localmente, que elimina um eixo de incompatibilidade."
  type        = string
  default     = "3.13"
}

variable "funcao_ligada" {
  description = "Liga os endpoints de interface que o mapeamento de origem de eventos da função serverless exige. Só o perfil Base + função liga: os endpoints são cobrados por hora, e a sessão comum não tem função."
  type        = bool
  default     = false
}

variable "cd_politica_edicao" {
  description = "Liga a policy gerenciada de edição no namespace da aplicação para as roles do pipeline de entrega. Desligada, o pipeline entra só pelo RBAC próprio do grupo fcg-cd, sem acesso a Secret."
  type        = bool
  default     = true
}
