# Backbone de eventos
#
#   tabla (Stream) -> EventBridge Pipe -> SNS eventos -> consumidores (analytics.tf)
#
# El evento se deriva del write ya commiteado, no lo publica flujo: SNS y SQS no
# tienen Gateway Endpoint (flujo esta en la VPC sin NAT) y publicar despues de la
# transaccion dejaria una doble escritura sin atomicidad. Si esta en DynamoDB,
# el Stream lo emite. Ver notas/eventos-y-mensajeria.md

# topic de eventos

# Sin SSE: SNS solo cifra con KMS, y la llave administrada aws/sns no autoriza a
# los servicios que publican (EventBridge) ni a CloudWatch. Haria falta una CMK
# propia, que en el lab no usamos (ver notas/seguridad.md). Los mensajes viajan
# por TLS y no llevan secretos
#tfsec:ignore:aws-sns-enable-topic-encryption
resource "aws_sns_topic" "eventos" {
  name = "${var.project}-solicitud-evento"
  tags = local.tags
}

# DLQ del puente: un registro del Stream que no se pudo publicar en el SNS
# despues de los reintentos queda aca en vez de perderse
#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "eventos_dlq" {
  name                      = "${var.project}-eventos-dlq"
  message_retention_seconds = 1209600 # 14 dias, el maximo
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

# puente Stream -> SNS con EventBridge Pipes (sin Lambda intermedia)

resource "aws_pipes_pipe" "eventos" {
  count = var.use_eventbridge_pipe ? 1 : 0

  name     = "${var.project}-eventos"
  role_arn = data.aws_iam_role.lab.arn
  source   = aws_dynamodb_table.this.stream_arn
  target   = aws_sns_topic.eventos.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position      = "LATEST"
      batch_size             = 10
      maximum_retry_attempts = 5

      dead_letter_config {
        arn = aws_sqs_queue.eventos_dlq.arn
      }
    }

    filter_criteria {
      filter {
        pattern = local.filtro_eventos
      }
    }
  }

  tags = local.tags

  # El Stream arranca en LATEST: si el puente existe antes de cargar el seed, sus
  # INSERT entrarian como eventos nuevos y duplicarian los del historico en S3
  depends_on = [aws_dynamodb_table_item.solicitud]
}

# puente alternativo con Lambda, solo si use_eventbridge_pipe = false

# Fuera de la VPC: SNS no tiene Gateway Endpoint. No consulta la tabla, reenvia
# el registro que le entrega el Stream
module "publicador" {
  source = "../modules/lambda_function"
  count  = var.use_eventbridge_pipe ? 0 : 1

  name        = "${var.project}-publicador"
  source_dir  = "${path.module}/../../back/functions/publicador"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn]
  memory_size = 256

  environment = {
    TOPIC_ARN = aws_sns_topic.eventos.arn
  }

  tags = local.tags
}

resource "aws_lambda_event_source_mapping" "publicador" {
  count = var.use_eventbridge_pipe ? 0 : 1

  function_name                  = module.publicador[0].arn
  event_source_arn               = aws_dynamodb_table.this.stream_arn
  starting_position              = "LATEST"
  batch_size                     = 10
  maximum_retry_attempts         = 5
  bisect_batch_on_function_error = true
  function_response_types        = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      pattern = local.filtro_eventos
    }
  }

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.eventos_dlq.arn
    }
  }

  # Igual que el Pipe: que el seed no pase por el puente
  depends_on = [aws_dynamodb_table_item.solicitud]
}
