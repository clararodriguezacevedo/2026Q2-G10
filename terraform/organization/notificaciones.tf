# Notificaciones por mail, con SNS como transporte
#
#   SNS eventos -> Lambda notif-cliente (fuera de VPC) -+
#               -> Lambda matcher (VPC, query GSI)      -+-on-success-> SQS notificaciones
#                                                          -> Lambda publicar-notificacion (fuera de VPC)
#                                                             -> SNS topic del usuario (barriofix-user-<sub>) -> mail
#
#   Registro (Stream, INSERT de un PERFIL) -> Lambda suscribir-usuario (fuera de VPC)
#                                             -> crea el topic del usuario + suscribe su email
#
# Cada usuario tiene su propio topic SNS (un publish le llega a TODOS los
# suscriptores, asi que no se puede compartir). El nombre se deriva del sub, asi
# que las Lambdas saben a cual publicar sin guardarlo. SNS manda el mail de
# confirmacion al suscribir; el usuario hace un click una vez.
#
# No usamos SES (el lab lo bloquea) ni un proveedor externo: SNS manda los mails
# por si mismo. notif-cliente y matcher no pueden llamar a SNS desde la VPC
# (sin Gateway Endpoint), asi que la publicacion la hace publicar-notificacion,
# fuera de la VPC, alimentada por Lambda Destinations. Ver notas/eventos-y-mensajeria.md

locals {
  notif_timeout = 30
}

# notif-cliente: avisa a la otra parte de cada cambio de estado

# Fuera de la VPC: ya no lee DynamoDB (el destinatario es el sub del evento)
module "notif_cliente" {
  source = "../modules/lambda_function"

  name        = "${var.project}-notif-cliente"
  source_dir  = "${path.module}/../../back/functions/notif_cliente"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 256

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
  filter_policy_scope = "MessageBody"
  filter_policy       = jsonencode({ eventName = ["MODIFY"] })

  depends_on = [aws_lambda_permission.sns_notif_cliente]
}

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "notif_dlq" {
  name                      = "${var.project}-notif-cliente-dlq"
  message_retention_seconds = 1209600 # 14 dias, el maximo
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

resource "aws_lambda_function_event_invoke_config" "notif_cliente" {
  function_name = module.notif_cliente.function_name

  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_success {
      destination = aws_sqs_queue.notificaciones.arn
    }
    on_failure {
      destination = aws_sqs_queue.notif_dlq.arn
    }
  }
}

# matcher: avisa a los profesionales que matchean (en la VPC, consulta el GSI)

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

  # Solo solicitudes que quedan en PENDIENTE: las nuevas y las liberadas
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
      destination = aws_sqs_queue.notificaciones.arn
    }
    on_failure {
      destination = aws_sqs_queue.matcher_dlq.arn
    }
  }
}

# cola de notificaciones (el on-success de notif-cliente y matcher)

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "notificaciones_dlq" {
  name                      = "${var.project}-notificaciones-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "notificaciones" {
  name                       = "${var.project}-notificaciones"
  visibility_timeout_seconds = 6 * local.notif_timeout
  message_retention_seconds  = 345600 # 4 dias
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.notificaciones_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.tags
}

# publicar-notificacion: unica funcion que manda mails (publica a SNS)

# Fuera de la VPC: SNS no tiene Gateway Endpoint. No toca datos
module "publicar_notificacion" {
  source = "../modules/lambda_function"

  name        = "${var.project}-publicar-notificacion"
  source_dir  = "${path.module}/../../back/functions/publicar_notificacion"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 256
  timeout     = local.notif_timeout

  environment = {
    CUENTA = local.account_id
  }

  tags = local.tags
}

resource "aws_lambda_event_source_mapping" "publicar_notificacion" {
  function_name    = module.publicar_notificacion.arn
  event_source_arn = aws_sqs_queue.notificaciones.arn
  batch_size       = 10

  # Tope de publicaciones en paralelo. Se limita aca y no con reserved
  # concurrency, asi los mensajes esperan en la cola en vez de rebotar
  scaling_config {
    maximum_concurrency = var.notif_max_concurrency
  }

  function_response_types = ["ReportBatchItemFailures"]
}

# suscribir-usuario: crea el topic del usuario y suscribe su email al registrarse

# Fuera de la VPC: llama a SNS. Lee el sub y el email del evento del Stream
module "suscribir_usuario" {
  source = "../modules/lambda_function"

  name        = "${var.project}-suscribir-usuario"
  source_dir  = "${path.module}/../../back/functions/suscribir_usuario"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 256

  tags = local.tags
}

resource "aws_lambda_event_source_mapping" "suscribir_usuario" {
  function_name    = module.suscribir_usuario.arn
  event_source_arn = aws_dynamodb_table.this.stream_arn
  # TRIM_HORIZON para que, en un deploy limpio, procese tambien los PERFIL del
  # seed (los usuarios de demo). Es idempotente: create_topic y subscribe no
  # duplican. Si fuera LATEST podria perderse el seed segun el orden del apply
  starting_position = "TRIM_HORIZON"
  batch_size        = 10

  # Solo los INSERT de un item PERFIL (un registro, de demo o real)
  filter_criteria {
    filter {
      pattern = jsonencode({ eventName = ["INSERT"], dynamodb = { Keys = { SK = { S = ["PERFIL"] } } } })
    }
  }

  function_response_types = ["ReportBatchItemFailures"]

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.suscribir_dlq.arn
    }
  }
}

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "suscribir_dlq" {
  name                      = "${var.project}-suscribir-usuario-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

# Los topics de usuario (de demo y reales) los crea suscribir-usuario en runtime,
# no Terraform: si Terraform tambien los creara, chocarian con los que ya hizo la
# Lambda al procesar el seed ("Topic already exists"). El workflow de destroy
# borra todos los barriofix-user-* para que no quede nada huerfano.
