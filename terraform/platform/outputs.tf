# so o ARN do segredo: quem precisa da credencial a le do gerenciador de segredos
# com a propria identidade. A senha nao sai deste root por output nenhum.
output "broker_secret_arn" {
  description = "ARN do segredo com a credencial do broker. Entrada obrigatória do root da função serverless."
  value       = aws_secretsmanager_secret.broker.arn
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
