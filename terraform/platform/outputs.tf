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

output "tg_arn" {
  description = "ARN do grupo de alvos do Traefik, consumido pelo TargetGroupBinding no cluster."
  value       = aws_lb_target_group.traefik.arn
}

# o root de sessao le este valor para abrir a porta dos nos so para o
# balanceador, sem que este root precise conhecer o grupo dos nos.
output "nlb_security_group_id" {
  description = "Grupo de segurança do balanceador interno, origem da regra de entrada nos nós do cluster."
  value       = aws_security_group.nlb.id
}

output "ecr_repository_urls" {
  description = "Endereço do repositório de imagem de cada serviço."
  value       = { for k, r in aws_ecr_repository.servico : k => r.repository_url }
}

output "cd_role_arns" {
  description = "ARN da role do CD de cada serviço; é o valor das variáveis do GitHub no pipeline."
  value       = { for k, r in aws_iam_role.cd : k => r.arn }
}

output "pod_role_arns" {
  description = "ARN das roles de Pod Identity, por componente, para as associações criadas com o cluster."
  value = {
    catalog = aws_iam_role.pod_catalog.arn
    lbc     = aws_iam_role.pod_lbc.arn
    ebs_csi = aws_iam_role.pod_ebs_csi.arn
  }
}
