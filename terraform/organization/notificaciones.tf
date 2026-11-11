# Notificaciones por mail
#
#   SNS eventos -> Lambda notif-cliente (VPC) -+
#               -> Lambda matcher (VPC)       -+-destino on-success-> SQS email
#                                                -> Lambda enviar-email (fuera de la VPC) -> SMTP
#
# notif-cliente avisa a la otra parte de cada cambio de estado; el matcher avisa
# a los profesionales que matchean un trabajo disponible. Las dos leen DynamoDB,
# asi que van en la VPC. Como SQS no tiene Gateway Endpoint, no encolan: devuelven
# el mail (o la lista de mails) y el destino on-success de la invocacion
# asincronica lo deja en la cola (lo entrega el servicio Lambda). La cola esta
# para frenar contra el rate limit del proveedor SMTP.
# Ver notas/eventos-y-mensajeria.md

locals {
  email_timeout = 30
}

# notif-cliente: SNS -> Lambda directo

module "notif_cliente" {
  source = "../modules/lambda_function"

  name        = "${var.project}-notif-cliente"
  source_dir  = "${path.module}/../../back/functions/notif_cliente"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 512

  environment = {
    TABLA = aws_dynamodb_table.this.name
  }

  vpc_config = {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  tags = local.tags
}

resource "aws_lambda_permission" "sns_notif_cliente" {
  statement_id  = "AllowSnsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.notif_cliente.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.eventos.arn
}

resource "aws_sns_topic_subscription" "notif_cliente" {
  topic_arn = aws_sns_topic.eventos.arn
  protocol  = "lambda"
  endpoint  = module.notif_cliente.arn

  # Solo cambios sobre solicitudes que ya existian: la creacion no se avisa
  # (la hizo el mismo cliente). Filtra SNS, sin invocar la Lambda
  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ eventName = ["MODIFY"] })

  depends_on = [aws_lambda_permission.sns_notif_cliente]
}

# DLQ de notif-cliente: invocaciones que fallaron despues de los reintentos
#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "notif_dlq" {
  name                      = "${var.project}-notif-cliente-dlq"
  message_retention_seconds = 1209600 # 14 dias, el maximo
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_lambda_function_event_invoke_config" "notif_cliente" {
  function_name = module.notif_cliente.function_name

  # Lambda reintenta sola la invocacion asincronica; un evento de mas de una
  # hora ya no vale la pena avisarlo
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_success {
      destination = aws_sqs_queue.email.arn
    }
    on_failure {
      destination = aws_sqs_queue.notif_dlq.arn
    }
  }
}

# matcher: SNS -> Lambda directo, solo trabajos que quedan disponibles

module "matcher" {
  source = "../modules/lambda_function"

  name        = "${var.project}-matcher"
  source_dir  = "${path.module}/../../back/functions/matcher"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 512

  environment = {
    TABLA = aws_dynamodb_table.this.name
  }

  vpc_config = {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  tags = local.tags
}

resource "aws_lambda_permission" "sns_matcher" {
  statement_id  = "AllowSnsInvoke"
  action        = "lambda:InvokeFunction"
  function_name = module.matcher.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.eventos.arn
}

resource "aws_sns_topic_subscription" "matcher" {
  topic_arn = aws_sns_topic.eventos.arn
  protocol  = "lambda"
  endpoint  = module.matcher.arn

  # Solo solicitudes que quedan en PENDIENTE: las nuevas y las liberadas. El
  # resto de los cambios ni siquiera invoca la Lambda
  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ dynamodb = { NewImage = { estado = { S = ["PENDIENTE"] } } } })

  depends_on = [aws_lambda_permission.sns_matcher]
}

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "matcher_dlq" {
  name                      = "${var.project}-matcher-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_lambda_function_event_invoke_config" "matcher" {
  function_name = module.matcher.function_name

  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_success {
      destination = aws_sqs_queue.email.arn
    }
    on_failure {
      destination = aws_sqs_queue.matcher_dlq.arn
    }
  }
}

# cola email

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "email_dlq" {
  name                      = "${var.project}-email-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "email" {
  name                       = "${var.project}-email"
  visibility_timeout_seconds = 6 * local.email_timeout
  # Si el proveedor SMTP se cae un rato, los mails esperan hasta 4 dias
  message_retention_seconds = 345600
  sqs_managed_sse_enabled   = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.email_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.tags
}

# credencial SMTP

# Terraform crea el secreto con un valor de relleno y no lo vuelve a tocar: el
# real lo carga el pipeline desde los secrets de GitHub (put-secret-value), asi
# la credencial nunca pasa por el codigo, el PR ni el state.
# Sin CMK propia, igual que el resto (ver notas/seguridad.md)
#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "smtp" {
  name                    = "${var.project}-smtp"
  description             = "Credencial SMTP del proveedor de mails (la usa enviar-email)"
  recovery_window_in_days = 0
  tags                    = local.tags
}

resource "aws_secretsmanager_secret_version" "smtp" {
  secret_id = aws_secretsmanager_secret.smtp.id
  # Sin credencial cargada, enviar-email simula los envios y los deja en el log
  secret_string = jsonencode({ configurado = false })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# enviar-email: SQS -> Lambda

# Fuera de la VPC: habla con el proveedor SMTP por internet. No toca datos
module "enviar_email" {
  source = "../modules/lambda_function"

  name        = "${var.project}-enviar-email"
  source_dir  = "${path.module}/../../back/functions/enviar_email"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn]
  memory_size = 256
  timeout     = local.email_timeout

  environment = {
    SMTP_SECRET_ARN = aws_secretsmanager_secret.smtp.arn
  }

  tags = local.tags
}

resource "aws_lambda_event_source_mapping" "enviar_email" {
  function_name    = module.enviar_email.arn
  event_source_arn = aws_sqs_queue.email.arn
  batch_size       = 10

  # Tope de envios en paralelo contra el proveedor SMTP. Se limita aca y no con
  # reserved concurrency: asi los mensajes esperan en la cola en vez de rebotar
  # por throttling y gastar reintentos
  scaling_config {
    maximum_concurrency = var.email_max_concurrency
  }

  function_response_types = ["ReportBatchItemFailures"]
}
