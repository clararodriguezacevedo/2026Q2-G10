"""Crea el topic SNS del usuario y suscribe su email, al crearse el perfil.

La dispara el DynamoDB Stream, filtrado a los INSERT de un item PERFIL. Va FUERA
de la VPC porque llama a SNS (sin Gateway Endpoint) y no toca DynamoDB: el sub y
el email vienen en la imagen del evento. El topic se llama barriofix-user-<sub>.

SNS manda el mail de confirmacion al suscribir; el usuario hace un click una vez,
y recien ahi empieza a recibir las notificaciones. Es idempotente: CreateTopic
devuelve el mismo ARN y re-suscribir un email ya confirmado no duplica nada.

Los usuarios de demo ya tienen su topic y suscripcion creados por Terraform; esta
Lambda cubre a los que se registran despues del deploy.
"""

import boto3
from aws_lambda_powertools import Logger
from botocore.exceptions import ClientError

from barriofix import eventos, notificaciones

logger = Logger(service="suscribir-usuario")

sns = boto3.client("sns")


@logger.inject_lambda_context
def handler(event, context):
    fallidos = []
    for registro in event.get("Records", []):
        imagen = eventos.deserializar(registro.get("dynamodb", {}).get("NewImage", {}))
        sub = (imagen.get("PK") or "").removeprefix("USER#")
        email = imagen.get("email")
        if not sub or not email:
            continue
        try:
            arn = sns.create_topic(Name=notificaciones.topic_name(sub))["TopicArn"]
            sns.subscribe(TopicArn=arn, Protocol="email", Endpoint=email, ReturnSubscriptionArn=True)
            logger.info("usuario suscripto al topic", extra={"sub": sub})
        except ClientError:
            logger.exception("no se pudo suscribir", extra={"sub": sub})
            fallidos.append(registro["dynamodb"]["SequenceNumber"])
    return {"batchItemFailures": [{"itemIdentifier": s} for s in fallidos]}
