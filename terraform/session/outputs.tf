output "broker_name" {
  description = "Nome do broker. Entrada obrigatória do root da função serverless e chave da descoberta pelo script de sessão."
  value       = aws_mq_broker.sessao.broker_name
}

# so o endereco: a credencial fica no gerenciador de segredos, e quem precisa dela
# a le de la pelo perfil de instancia. nenhum output deste root a referencia.
output "broker_endpoint" {
  description = "Endereço do broker dentro da VPC. É o valor de RabbitMq__Host da sessão."
  value       = aws_mq_broker.sessao.instances[0].endpoints[0]
}
