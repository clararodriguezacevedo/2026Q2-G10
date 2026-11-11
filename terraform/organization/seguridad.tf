# Deteccion a nivel cuenta: GuardDuty, Inspector, Config y Security Hub
#
# Se activan por cuenta y no los llaman las Lambdas, asi que no necesitan roles
# por funcion. Cada uno se prende con var.servicios_seguridad (count): en el
# Learner Lab hay que verificar antes que el servicio este permitido, porque si
# no el apply falla y el despliegue entero queda a medias.
# Ver notas/seguridad.md

locals {
  seguridad = var.servicios_seguridad

  # Lo que registra Config: los tipos de recurso que usa el proyecto, no todos
  # los de la cuenta (Config cobra por cada cambio registrado)
  config_tipos = [
    "AWS::Lambda::Function",
    "AWS::DynamoDB::Table",
    "AWS::S3::Bucket",
    "AWS::SQS::Queue",
    "AWS::SNS::Topic",
    "AWS::ApiGatewayV2::Api",
    "AWS::ApiGatewayV2::Stage",
    "AWS::SecretsManager::Secret",
    "AWS::EC2::VPC",
    "AWS::EC2::Subnet",
    "AWS::EC2::SecurityGroup",
    "AWS::EC2::VPCEndpoint",
  ]
}

# GuardDuty: deteccion de amenazas

# Analiza CloudTrail, DNS y flujos de red de la cuenta buscando actividad
# anomala (credenciales usadas desde lugares raros, llamadas a hosts maliciosos)
resource "aws_guardduty_detector" "this" {
  count = local.seguridad.guardduty ? 1 : 0

  enable = true
  # Por defecto publica hallazgos cada 6 horas
  finding_publishing_frequency = "FIFTEEN_MINUTES"
  tags                         = local.tags
}

# Mira tambien la red de las Lambdas: por ejemplo, una funcion que empieza a
# hablar con un host conocido por minar criptomonedas
resource "aws_guardduty_detector_feature" "lambda" {
  count = local.seguridad.guardduty ? 1 : 0

  detector_id = aws_guardduty_detector.this[0].id
  name        = "LAMBDA_NETWORK_LOGS"
  status      = "ENABLED"
}

# Inspector: vulnerabilidades en las Lambdas

# Escanea los paquetes y layers de cada Lambda buscando dependencias con CVEs
# conocidos (LAMBDA) y el codigo propio buscando problemas de seguridad
# (LAMBDA_CODE). Es el escaneo que encaja con un backend 100% serverless
resource "aws_inspector2_enabler" "this" {
  count = local.seguridad.inspector ? 1 : 0

  account_ids    = [local.account_id]
  resource_types = ["LAMBDA", "LAMBDA_CODE"]
}

# Config: historial de configuracion

# Bucket propio para el historial, separado de los datos de la app
resource "awscc_s3_bucket" "config" {
  count = local.seguridad.config ? 1 : 0

  bucket_name = local.bucket_config

  lifecycle_configuration = {
    rules = [{
      id                 = "expirar-historial"
      status             = "Enabled"
      expiration_in_days = 90
    }]
  }

  public_access_block_configuration = {
    block_public_acls       = true
    block_public_policy     = true
    ignore_public_acls      = true
    restrict_public_buckets = true
  }
}

# Config entrega el historial al bucket asumiendo su rol, asi que el bucket tiene
# que dejarlo escribir. Sin esta policy, PutDeliveryChannel falla con
# InsufficientDeliveryPolicyException
resource "awscc_s3_bucket_policy" "config" {
  count = local.seguridad.config ? 1 : 0

  bucket = awscc_s3_bucket.config[0].id
  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = ["s3:GetBucketAcl", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.bucket_config}"
      },
      {
        Sid       = "Write"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::${local.bucket_config}/AWSLogs/${local.account_id}/Config/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
    ]
  })
}

# Graba cada cambio de configuracion de esos recursos. Usa el LabRole porque en
# el lab no se puede crear el rol de servicio de Config
resource "aws_config_configuration_recorder" "this" {
  count = local.seguridad.config ? 1 : 0

  name     = var.project
  role_arn = data.aws_iam_role.lab.arn

  recording_group {
    all_supported  = false
    resource_types = local.config_tipos
  }
}

resource "aws_config_delivery_channel" "this" {
  count = local.seguridad.config ? 1 : 0

  name           = var.project
  s3_bucket_name = awscc_s3_bucket.config[0].bucket_name

  # El canal necesita el recorder y que el bucket ya deje escribir a Config
  depends_on = [aws_config_configuration_recorder.this, awscc_s3_bucket_policy.config]
}

resource "aws_config_configuration_recorder_status" "this" {
  count = local.seguridad.config ? 1 : 0

  name       = aws_config_configuration_recorder.this[0].name
  is_enabled = true

  # Arrancar a grabar recien cuando hay a donde entregar
  depends_on = [aws_config_delivery_channel.this]
}

# Security Hub: panel unico

# Junta los hallazgos de GuardDuty e Inspector (se integran solos) y evalua la
# cuenta contra AWS Foundational Security Best Practices, cuyos controles leen
# lo que graba Config (por eso la variable exige Config para prenderlo)
resource "aws_securityhub_account" "this" {
  count = local.seguridad.security_hub ? 1 : 0

  # Solo el standard que elegimos, no todos los que activa por defecto
  enable_default_standards = false
  auto_enable_controls     = true
}

resource "aws_securityhub_standards_subscription" "fsbp" {
  count = local.seguridad.security_hub ? 1 : 0

  standards_arn = "arn:aws:securityhub:${var.region}::standards/aws-foundational-security-best-practices/v/1.0.0"

  depends_on = [aws_securityhub_account.this]
}
