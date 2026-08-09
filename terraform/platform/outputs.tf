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
