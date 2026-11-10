"""Consumidor de analytics: vuelca los eventos de las solicitudes a S3 para Athena.

La dispara la cola SQS analytics, suscrita al topic de eventos con raw message
delivery: el body de cada mensaje es el registro del DynamoDB Stream tal cual.

Procesa en lote: agrupa los eventos por fecha y escribe un objeto JSON Lines por
particion (eventos/fecha=AAAA-MM-DD/), en vez de un PutObject por evento. Va
dentro de la VPC y escribe por el Gateway Endpoint de S3.

Si un PutObject falla se reportan solo esos mensajes (ReportBatchItemFailures)
y SQS los reintenta; despues de maxReceiveCount van a la DLQ. Cada evento lleva
el eventID del Stream, asi un reintento que llegue a duplicar se descarta en
Athena con DISTINCT.
"""

import json
import os
from collections import defaultdict

import boto3
from aws_lambda_powertools import Logger, Metrics
from aws_lambda_powertools.metrics import MetricUnit
from botocore.exceptions import ClientError

from barriofix import eventos
from barriofix.ids import ulid

logger = Logger(service="analytics")
# Metricas de observabilidad (EMF): cuantos eventos se escriben, no analytics de negocio
metrics = Metrics(namespace="BarrioFix", service="analytics")

s3 = boto3.client("s3")
BUCKET = os.environ["ANALYTICS_BUCKET"]
PREFIJO = "eventos"


@metrics.log_metrics
@logger.inject_lambda_context
def handler(event, context):
    fallidos = []
    por_fecha = defaultdict(list)  # fecha -> [(message_id, evento)]

    for mensaje in event.get("Records", []):
        try:
            evento = eventos.desde_registro_stream(json.loads(mensaje["body"]))
        except (ValueError, KeyError, TypeError):
            # Nunca va a poder procesarse: que agote los reintentos y quede en la DLQ
            logger.exception("mensaje ilegible", extra={"message_id": mensaje.get("messageId")})
            fallidos.append(mensaje["messageId"])
            continue
        if evento is None:
            continue  # cambio sin valor analitico, por ejemplo una foto nueva
        por_fecha[evento["ts"][:10]].append((mensaje["messageId"], evento))

    for fecha, lote in por_fecha.items():
        cuerpo = "".join(json.dumps(e, ensure_ascii=False) + "\n" for _, e in lote)
        key = f"{PREFIJO}/fecha={fecha}/{ulid()}.json"
        try:
            s3.put_object(Bucket=BUCKET, Key=key, Body=cuerpo.encode(), ContentType="application/x-ndjson")
        except ClientError:
            logger.exception("no se pudo escribir el lote", extra={"key": key})
            fallidos.extend(message_id for message_id, _ in lote)
            continue
        metrics.add_metric(name="EventosEscritos", unit=MetricUnit.Count, value=len(lote))

    if fallidos:
        metrics.add_metric(name="MensajesFallidos", unit=MetricUnit.Count, value=len(fallidos))
    return {"batchItemFailures": [{"itemIdentifier": m} for m in fallidos]}
