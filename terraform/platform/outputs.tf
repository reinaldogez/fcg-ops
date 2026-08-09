output "dynamodb_table_name" {
  description = "Nome da tabela do read model, o mesmo que o ConfigMap do catalog injeta."
  value       = aws_dynamodb_table.biblioteca.name
}

output "dynamodb_table_arn" {
  description = "ARN da tabela do read model."
  value       = aws_dynamodb_table.biblioteca.arn
}

# so o ARN do segredo: quem precisa da credencial a le do gerenciador de segredos
# pelo perfil de instancia. A senha nao sai deste root por output nenhum.
output "broker_secret_arn" {
  description = "ARN do segredo com a credencial do broker. Entrada obrigatória do root da função serverless."
  value       = aws_secretsmanager_secret.broker.arn
}

output "instance_profile_name" {
  description = "Nome do perfil de instância que carrega as permissões do cluster."
  value       = aws_iam_instance_profile.instancia.name
}

output "instance_public_ip" {
  description = "Endereço fixo do nó do cluster. É por ele que passam o acesso administrativo e os túneis da sessão."
  value       = aws_eip.cluster.public_ip
}

output "instance_id" {
  description = "Identificador da instância do cluster, alvo da parada e da partida de cada sessão."
  value       = aws_instance.cluster.id
}

output "api_invoke_url" {
  description = "URL de invocação do stage padrão. É o endereço público do sistema inteiro."
  value       = aws_apigatewayv2_stage.padrao.invoke_url
}

# o mesmo valor da URL de invocacao, e nomeado assim de proposito: quem configura
# a sessao de nuvem copia este output em vez de reconstruir a string, e a
# reconstrucao a mao erra acrescentando sufixo de stage por habito -- erro que nao
# aparece no apply, so na primeira requisicao.
output "api_issuer" {
  description = "Issuer que o gateway exige no token, montado a partir do identificador da API. Valor de Jwt__Issuer dos serviços."
  value       = local.api_issuer
}

output "api_id" {
  description = "Identificador da API HTTP, pelo qual o inventário casa o recurso sem depender do nome."
  value       = aws_apigatewayv2_api.fcg.id
}
