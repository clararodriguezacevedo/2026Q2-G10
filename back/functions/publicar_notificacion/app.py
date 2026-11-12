"""Unica Lambda que manda mails: publica cada aviso al topic SNS del usuario.

Consume la cola de notificaciones (el destino on-success de notif-cliente y
matcher). Va FUERA de la VPC porque SNS no tiene Gateway Endpoint. No toca datos:
cada aviso trae {sub, asunto, texto}. El topic del usuario es
barriofix-user-<sub> (deterministico); al publicar ahi, SNS manda el mail a los
suscriptores confirmados de ese topic.

`create_topic` es idempotente: asegura que el topic exista por si una
notificacion llega antes de que el usuario se haya suscripto. Un mensaje puede
traer un aviso (notif-cliente) o varios (matcher); si falla a la mitad, se
reintenta entero ("al menos una vez").
"""

import json
import os

import boto3
from aws_lambda_powertools import Logger
from botocore.exceptions import ClientError

from barriofix import notificaciones

logger = Logger(service="publicar-notificacion")

sns = boto3.client("sns")
# AWS_REGION lo provee el runtime de Lambda; CUENTA lo pone Terraform
REGION = os.environ["AWS_REGION"]
CUENTA = os.environ["CUENTA"]


@logger.inject_lambda_context
def handler(event, context):
    fallidos = []
    for mensaje in event.get("Records", []):
        try:
            payload = json.loads(mensaje["body"]).get("responsePayload")
        except (ValueError, AttributeError):
            logger.exception("mensaje ilegible", extra={"message_id": mensaje["messageId"]})
            fallidos.append(mensaje["messageId"])
            continue
        if not payload:
            continue  # el cambio no se avisaba (responsePayload vacio)

        avisos = payload if isinstance(payload, list) else [payload]
        try:
            for aviso in avisos:
                nombre = notificaciones.topic_name(aviso["sub"])
                # Idempotente; si el topic ya existe, devuelve el mismo ARN
                sns.create_topic(Name=nombre)
                sns.publish(
                    TopicArn=f"arn:aws:sns:{REGION}:{CUENTA}:{nombre}",
                    Subject=notificaciones.asunto_sns(aviso["asunto"]),
                    Message=aviso["texto"],
                )
        except ClientError:
            logger.exception("fallo al publicar en SNS", extra={"message_id": mensaje["messageId"]})
            fallidos.append(mensaje["messageId"])

    return {"batchItemFailures": [{"itemIdentifier": m} for m in fallidos]}
