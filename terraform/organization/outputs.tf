output "region" {
  description = "Region de AWS"
  value       = var.region
}

output "cognito_user_pool_id" {
  description = "ID del user pool de Cognito (va en config.json del front)"
  value       = aws_cognito_user_pool.this.id
}

output "cognito_client_id" {
  description = "ID del app client de Cognito (va en config.json del front)"
  value       = aws_cognito_user_pool_client.web.id
}

output "cognito_domain" {
  description = "Dominio de la Hosted UI"
  value       = "${local.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com"
}

output "api_url" {
  description = "URL base de la API (va en config.json del front)"
  value       = aws_apigatewayv2_api.http.api_endpoint
}

output "hosted_ui_login_url" {
  description = "URL de login de la Hosted UI (el front redirige aca)"
  value       = "https://${local.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com/login?client_id=${aws_cognito_user_pool_client.web.id}&response_type=code&scope=openid+email+profile&redirect_uri=${aws_apigatewayv2_api.http.api_endpoint}/callback"
}

output "dynamodb_table" {
  description = "Nombre de la tabla de DynamoDB"
  value       = aws_dynamodb_table.this.name
}

output "media_bucket" {
  description = "Bucket de las fotos"
  value       = awscc_s3_bucket.media.bucket_name
}

output "frontend_bucket" {
  description = "Bucket del sitio estatico"
  value       = awscc_s3_bucket.frontend.bucket_name
}

output "frontend_url" {
  description = "URL publica del sitio (website endpoint de S3)"
  value       = "http://${local.bucket_front}.s3-website-${var.region}.amazonaws.com"
}

output "eventos_topic_arn" {
  description = "Topic SNS donde se publican los eventos de las solicitudes"
  value       = aws_sns_topic.eventos.arn
}

output "analytics_bucket" {
  description = "Bucket con los eventos crudos para Athena"
  value       = awscc_s3_bucket.analytics.bucket_name
}

output "athena_workgroup" {
  description = "Workgroup de Athena con las consultas de negocio guardadas"
  value       = aws_athena_workgroup.analytics.name
}

output "smtp_secret_arn" {
  description = "Secreto con la credencial SMTP; el valor real lo carga el pipeline, no Terraform"
  value       = aws_secretsmanager_secret.smtp.arn
}

output "vpc_id" {
  description = "ID de la VPC que crea el modulo externo"
  value       = module.vpc.vpc_id
}

output "app_subnet_ids" {
  description = "Subredes privadas donde van las ENIs de las Lambdas"
  value       = module.vpc.private_subnets
}

output "lambda_security_group_id" {
  description = "Security group de las Lambdas que van dentro de la VPC"
  value       = aws_security_group.lambda.id
}
