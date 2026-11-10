"""Puente Stream -> SNS, solo si el lab no permite usar EventBridge Pipes.

Hace lo mismo que el Pipe: publica en el topic de eventos cada registro del
Stream, tal cual y ya filtrado por el event source mapping (solo la META de las
solicitudes). Asi los consumidores reciben el mismo mensaje con cualquiera de
los dos puentes.

Va FUERA de la VPC porque SNS no tiene Gateway Endpoint. No consulta DynamoDB:
solo reenvia el payload que le entrega el Stream.
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger
from botocore.exceptions import ClientError

logger = Logger(service="publicador")

sns = boto3.client("sns")
TOPIC_ARN = os.environ["TOPIC_ARN"]


@logger.inject_lambda_context
def handler(event, context):
    for registro in event.get("Records", []):
        try:
            sns.publish(TopicArn=TOPIC_ARN, Message=json.dumps(registro, default=str))
        except ClientError:
            # En un stream el orden importa: se corta en el primero que falla y
            # Lambda reintenta desde ahi (los anteriores ya se publicaron)
            logger.exception("no se pudo publicar", extra={"event_id": registro.get("eventID")})
            return {"batchItemFailures": [{"itemIdentifier": registro["dynamodb"]["SequenceNumber"]}]}
    return {"batchItemFailures": []}
