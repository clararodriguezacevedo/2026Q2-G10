# Observabilidad operativa: alarmas de CloudWatch sobre la mensajeria.
# Es salud del sistema (que no se degrade nada), no analytics de negocio

# Topic de alarmas. Sin SSE por lo mismo que el de eventos: CloudWatch no puede
# publicar en un topic cifrado con la llave administrada aws/sns
#tfsec:ignore:aws-sns-enable-topic-encryption
resource "aws_sns_topic" "alarmas" {
  name = "${var.project}-alarmas"
  tags = local.tags
}

# El email recibe un link de confirmacion antes de empezar a llegar alarmas
resource "aws_sns_topic_subscription" "alarmas_email" {
  count = var.alarm_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.alarmas.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  # DLQ -> nombre de la cola. Agregar un consumidor con DLQ es sumar una entrada
  dlqs = {
    eventos       = aws_sqs_queue.eventos_dlq.name
    analytics     = aws_sqs_queue.analytics_dlq.name
    notif-cliente = aws_sqs_queue.notif_dlq.name
    matcher       = aws_sqs_queue.matcher_dlq.name
    email         = aws_sqs_queue.email_dlq.name
  }
}

# Un solo mensaje en una DLQ ya es un problema: agoto los reintentos y alguien
# tiene que mirarlo
resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = local.dlqs

  alarm_name        = "${var.project}-dlq-${each.key}"
  alarm_description = "Hay mensajes en la DLQ de ${each.key}: agotaron los reintentos"
  namespace         = "AWS/SQS"
  metric_name       = "ApproximateNumberOfMessagesVisible"
  dimensions        = { QueueName = each.value }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
  tags          = local.tags
}

locals {
  # Cola -> nombre. Con el batching (analytics) o el tope de concurrencia (email)
  # normales, ningun mensaje espera mas de un par de minutos
  colas_con_consumidor = {
    analytics = aws_sqs_queue.analytics.name
    email     = aws_sqs_queue.email.name
  }
}

# Mensajes que se apilan: el consumidor esta trabado o no da abasto. En email
# tambien avisa si el proveedor SMTP esta caido y los mails se acumulan
resource "aws_cloudwatch_metric_alarm" "cola_atrasada" {
  for_each = local.colas_con_consumidor

  alarm_name        = "${var.project}-${each.key}-atrasada"
  alarm_description = "El mensaje mas viejo de la cola ${each.key} tiene mas de 15 minutos"
  namespace         = "AWS/SQS"
  metric_name       = "ApproximateAgeOfOldestMessage"
  dimensions        = { QueueName = each.value }

  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 900
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarmas.arn]
  ok_actions    = [aws_sns_topic.alarmas.arn]
  tags          = local.tags
}
