output "broker_name" {
  description = "Nome do broker. Entrada obrigatória do root da função serverless e chave da descoberta pelo script de sessão."
  value       = aws_mq_broker.sessao.broker_name
}

# so o endereco: a credencial fica no gerenciador de segredos, e quem precisa dela
# a le de la com a propria identidade. nenhum output deste root a referencia.
output "broker_endpoint" {
  description = "Endereço do broker dentro da VPC. É o valor de RabbitMq__Host da sessão."
  value       = aws_mq_broker.sessao.instances[0].endpoints[0]
}

output "cluster_name" {
  description = "Nome do cluster EKS da sessão. É o argumento do update-kubeconfig no laptop e no pipeline."
  value       = module.eks.cluster_name
}

output "node_security_group_id" {
  description = "Grupo de segurança dos nós do cluster, por onde os pods saem."
  value       = module.eks.node_security_group_id
}

output "dynamodb_table_name" {
  description = "Nome da tabela do read model da biblioteca."
  value       = aws_dynamodb_table.biblioteca.name
}

output "opensearch_endpoint" {
  description = "Endereço do domínio de busca dentro da VPC, sem esquema."
  value       = aws_opensearch_domain.busca.endpoint
}
