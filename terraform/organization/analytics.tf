# Analytics de negocio: eventos crudos en S3, consultados con Athena
#
#   SNS eventos -> SQS analytics -> Lambda analytics (en lote) -> S3 -> Athena
#
# La cola esta por batching: la Lambda junta hasta 100 eventos y los escribe en
# pocos PutObject. CloudWatch queda para observabilidad, no para esto.
# Ver notas/eventos-y-mensajeria.md

locals {
  analytics_timeout = 30

  # Esquema de cada evento (lo arma barriofix/eventos.py). Una columna por campo
  analytics_columnas = [
    { name = "event_id", type = "string" },
    { name = "tipo", type = "string" },
    { name = "ts", type = "string" },
    { name = "id_solicitud", type = "string" },
    { name = "estado_anterior", type = "string" },
    { name = "estado_nuevo", type = "string" },
    { name = "id_categoria", type = "int" },
    { name = "id_zona", type = "int" },
    { name = "id_urgencia", type = "int" },
    { name = "id_cliente", type = "string" },
    { name = "id_profesional", type = "string" },
    { name = "fecha_creacion", type = "string" },
    { name = "puntuacion", type = "int" },
  ]

  # Consultas guardadas en Athena, una por archivo en sql/
  analytics_queries = toset([for f in fileset("${path.module}/sql", "*.sql") : trimsuffix(f, ".sql")])

  # Dimensiones para que las consultas muestren nombres y no ids. Salen del
  # mismo seed que DynamoDB: catalogos y usuarios de demo
  analytics_dimensiones = {
    categoria = [{ name = "id", type = "int" }, { name = "nombre", type = "string" }]
    zona      = [{ name = "id", type = "int" }, { name = "nombre", type = "string" }]
    urgencia  = [{ name = "id", type = "int" }, { name = "nombre", type = "string" }]
    usuario   = [{ name = "id", type = "string" }, { name = "nombre", type = "string" }, { name = "rol", type = "string" }]
  }
  analytics_dimension_filas = merge(
    {
      for tipo in ["categoria", "zona", "urgencia"] :
      tipo => [for k, v in local.seed_items : { id = v.id, nombre = v.nombre } if v.tipo == tipo]
    },
    {
      usuario = [
        for u, d in local.demo_users :
        { id = aws_cognito_user.demo[u].sub, nombre = "${d.nombre} ${d.apellido}", rol = d.rol }
      ]
    },
  )
}

# bucket

resource "awscc_s3_bucket" "analytics" {
  bucket_name = local.bucket_analytics

  # Los resultados de Athena son descartables: se borran solos a la semana
  lifecycle_configuration = {
    rules = [{
      id                 = "expirar-resultados-athena"
      status             = "Enabled"
      prefix             = "athena-resultados/"
      expiration_in_days = 7
    }]
  }

  public_access_block_configuration = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

# Eventos del seed: el mismo historial que seed_solicitudes.tf carga en DynamoDB,
# un objeto JSON Lines por dia como los que escribe la Lambda. Asi Athena tiene
# datos desde el primer deploy y coinciden con lo que muestra la app
resource "aws_s3_object" "eventos_seed" {
  for_each = local.eventos_seed_por_dia

  bucket       = awscc_s3_bucket.analytics.bucket_name
  key          = "eventos/fecha=${formatdate("YYYY-MM-DD", timeadd(local.seed_now, "${tonumber(each.key) * 24}h"))}/seed.json"
  content_type = "application/x-ndjson"

  content = join("", [
    for k in each.value : "${jsonencode({
      event_id        = "seed-${k}"
      tipo            = local.eventos_seed[k].tipo
      ts              = timeadd(local.seed_now, "${local.eventos_seed[k].offset_horas - local.eventos_seed[k].edad_horas}h")
      id_solicitud    = local.eventos_seed[k].id_solicitud
      estado_anterior = local.eventos_seed[k].estado_anterior
      estado_nuevo    = local.eventos_seed[k].estado_nuevo
      id_categoria    = local.eventos_seed[k].id_categoria
      id_zona         = local.eventos_seed[k].id_zona
      id_urgencia     = local.eventos_seed[k].id_urgencia
      id_cliente      = aws_cognito_user.demo[local.eventos_seed[k].cliente].sub
      id_profesional  = local.eventos_seed[k].profesional != null ? aws_cognito_user.demo[local.eventos_seed[k].profesional].sub : null
      fecha_creacion  = timeadd(local.seed_now, "-${local.eventos_seed[k].edad_horas}h")
      puntuacion      = local.eventos_seed[k].puntuacion
    })}\n"
  ])
}

# cola, DLQ y suscripcion al topic de eventos

#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "analytics_dlq" {
  name                      = "${var.project}-analytics-dlq"
  message_retention_seconds = 1209600 # 14 dias, el maximo
  sqs_managed_sse_enabled   = true
  tags                      = local.tags
}

# SSE administrado por SQS y no KMS: con la llave aws/sqs, SNS no puede entregar
#tfsec:ignore:aws-sqs-queue-encryption-use-cmk
resource "aws_sqs_queue" "analytics" {
  name = "${var.project}-analytics"
  # AWS pide que sea mayor al timeout de la Lambda; 6 veces es lo recomendado
  visibility_timeout_seconds = 6 * local.analytics_timeout
  sqs_managed_sse_enabled    = true

  # Un mensaje que falla 5 veces va a la DLQ en vez de reintentarse para siempre
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.analytics_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.tags
}

# Solo el topic de eventos puede escribir en la cola
resource "aws_sqs_queue_policy" "analytics" {
  queue_url = aws_sqs_queue.analytics.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SoloElTopicDeEventos"
      Effect    = "Allow"
      Principal = { Service = "sns.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.analytics.arn
      Condition = { ArnEquals = { "aws:SourceArn" = aws_sns_topic.eventos.arn } }
    }]
  })
}

resource "aws_sns_topic_subscription" "analytics" {
  topic_arn = aws_sns_topic.eventos.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.analytics.arn

  # El body llega sin el sobre de SNS: es el registro del Stream tal cual
  raw_message_delivery = true

  # Sin la policy, SNS no puede entregar y los primeros mensajes se pierden
  depends_on = [aws_sqs_queue_policy.analytics]
}

# Lambda consumidora

# Dentro de la VPC: solo habla con S3, por el Gateway Endpoint
module "analytics" {
  source = "../modules/lambda_function"

  name        = "${var.project}-analytics"
  source_dir  = "${path.module}/../../back/functions/analytics"
  role_arn    = data.aws_iam_role.lab.arn
  layers      = [var.powertools_layer_arn, aws_lambda_layer_version.common.arn]
  memory_size = 512
  timeout     = local.analytics_timeout

  environment = {
    ANALYTICS_BUCKET = local.bucket_analytics
  }

  vpc_config = {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.lambda.id]
  }

  tags = local.tags
}

resource "aws_lambda_event_source_mapping" "analytics" {
  function_name    = module.analytics.arn
  event_source_arn = aws_sqs_queue.analytics.arn
  batch_size       = 100

  # Espera hasta 30 s a juntar el lote: menos invocaciones y menos objetos en S3
  maximum_batching_window_in_seconds = 30

  # Si falla un PutObject se reintentan solo esos mensajes, no el lote entero
  function_response_types = ["ReportBatchItemFailures"]
}

# Athena: tabla sobre los eventos y consultas guardadas

resource "aws_glue_catalog_database" "analytics" {
  name = replace("${var.project}_analytics", "-", "_")
}

resource "aws_glue_catalog_table" "eventos" {
  name          = "eventos"
  database_name = aws_glue_catalog_database.analytics.name
  table_type    = "EXTERNAL_TABLE"

  # Partition projection: Athena calcula las particiones por fecha sin crawler
  # (un crawler de Glue necesitaria un rol propio, que el lab no deja crear)
  parameters = {
    EXTERNAL                         = "TRUE"
    "projection.enabled"             = "true"
    "projection.fecha.type"          = "date"
    "projection.fecha.format"        = "yyyy-MM-dd"
    "projection.fecha.range"         = "2026-01-01,NOW"
    "projection.fecha.interval"      = "1"
    "projection.fecha.interval.unit" = "DAYS"
    "storage.location.template"      = "s3://${local.bucket_analytics}/eventos/fecha=$${fecha}/"
  }

  partition_keys {
    name = "fecha"
    type = "string"
  }

  storage_descriptor {
    location      = "s3://${local.bucket_analytics}/eventos/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    # Un evento JSON por linea
    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    dynamic "columns" {
      for_each = local.analytics_columnas
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

resource "aws_s3_object" "dimension" {
  for_each = local.analytics_dimensiones

  bucket       = awscc_s3_bucket.analytics.bucket_name
  key          = "dimensiones/${each.key}/${each.key}.json"
  content_type = "application/x-ndjson"
  content      = join("", [for fila in local.analytics_dimension_filas[each.key] : "${jsonencode(fila)}\n"])
}

resource "aws_glue_catalog_table" "dimension" {
  for_each = local.analytics_dimensiones

  name          = each.key
  database_name = aws_glue_catalog_database.analytics.name
  table_type    = "EXTERNAL_TABLE"
  parameters    = { EXTERNAL = "TRUE" }

  storage_descriptor {
    location      = "s3://${local.bucket_analytics}/dimensiones/${each.key}/"
    input_format  = "org.apache.hadoop.mapred.TextInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.HiveIgnoreKeyTextOutputFormat"

    ser_de_info {
      serialization_library = "org.openx.data.jsonserde.JsonSerDe"
    }

    dynamic "columns" {
      for_each = each.value
      content {
        name = columns.value.name
        type = columns.value.type
      }
    }
  }
}

resource "aws_athena_workgroup" "analytics" {
  name = "${var.project}-analytics"

  # Si no, el destroy falla cuando el workgroup tiene consultas guardadas
  force_destroy = true

  configuration {
    # Nadie puede mandar los resultados a otro lado ni sin cifrar
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${local.bucket_analytics}/athena-resultados/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  tags = local.tags
}

# Los insights de negocio, listos para correr desde la consola de Athena. La
# primera linea de cada .sql es su descripcion
resource "aws_athena_named_query" "insight" {
  for_each = local.analytics_queries

  name        = each.key
  workgroup   = aws_athena_workgroup.analytics.id
  database    = aws_glue_catalog_database.analytics.name
  description = trimprefix(split("\n", file("${path.module}/sql/${each.key}.sql"))[0], "-- ")
  query       = templatefile("${path.module}/sql/${each.key}.sql", { db = aws_glue_catalog_database.analytics.name })

  # Las consultas leen todas las tablas de la base
  depends_on = [aws_glue_catalog_table.eventos, aws_glue_catalog_table.dimension]
}
