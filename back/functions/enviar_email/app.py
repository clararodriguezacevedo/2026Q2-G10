"""Unica Lambda que manda mails: consume la cola email y entrega por SMTP.

Va FUERA de la VPC porque habla con un proveedor SMTP externo (Mailtrap o
Brevo, puerto 587 con STARTTLS; el 25 esta bloqueado en Lambda). Por eso no
toca los datos: todo lo que necesita viene en el mensaje (para, asunto, texto).

Cada mensaje de la cola es el registro que deja el destino on-success de
notif-cliente o del matcher: en responsePayload viene un mail, una lista de
mails (el matcher avisa a varios profesionales) o nada si el cambio no se avisaba.
Si un mensaje con varios mails falla a la mitad, se reintenta entero: el envio es
"al menos una vez", como cualquier cola.

La credencial SMTP esta en Secrets Manager, cacheada 5 minutos. Mientras no se
cargue una real (el secreto trae {"configurado": false}), funciona en modo
simulacion: registra en el log que mail habria mandado y no falla.

La concurrencia la limita el event source mapping (maximum_concurrency), para no
pasarse del rate limit del proveedor: lo que no se llega a mandar espera en la cola.
"""

import json
import os
import smtplib
import ssl
from email.message import EmailMessage

from aws_lambda_powertools import Logger
from aws_lambda_powertools.utilities import parameters

logger = Logger(service="enviar-email")
SECRETO = os.environ["SMTP_SECRET_ARN"]


@logger.inject_lambda_context
def handler(event, context):
    fallidos = []
    mensajes = []  # (message_id, [mails])
    for mensaje in event.get("Records", []):
        try:
            payload = json.loads(mensaje["body"]).get("responsePayload")
        except (ValueError, AttributeError):
            logger.exception("mensaje ilegible", extra={"message_id": mensaje["messageId"]})
            fallidos.append(mensaje["messageId"])
            continue
        if payload:
            mensajes.append((mensaje["messageId"], payload if isinstance(payload, list) else [payload]))

    if mensajes:
        config = parameters.get_secret(SECRETO, transform="json", max_age=300)
        if config.get("configurado", True):
            fallidos += _enviar(config, mensajes)
        else:
            for _, mails in mensajes:
                for mail in mails:
                    logger.info("SMTP sin configurar, simulacion de envio", extra={"asunto": mail["asunto"]})

    return {"batchItemFailures": [{"itemIdentifier": m} for m in fallidos]}


def _enviar(config: dict, mensajes: list) -> list:
    """Manda los mails por una sola conexion. Devuelve los message_id a reintentar."""
    pendientes = [message_id for message_id, _ in mensajes]
    try:
        with smtplib.SMTP(config["host"], int(config.get("port", 587)), timeout=10) as smtp:
            smtp.starttls(context=ssl.create_default_context())
            smtp.login(config["usuario"], config["password"])
            for message_id, mails in mensajes:
                for mail in mails:
                    try:
                        smtp.send_message(_armar(config["remitente"], mail))
                    except smtplib.SMTPRecipientsRefused:
                        # Direccion invalida: reintentar no lo arregla
                        logger.warning("destinatario rechazado, se descarta", extra={"message_id": message_id})
                pendientes.remove(message_id)
    except (smtplib.SMTPException, OSError):
        # Conexion, login o un error temporal: vuelven a la cola los que faltaban
        logger.exception("fallo el envio por SMTP", extra={"pendientes": len(pendientes)})
        return pendientes
    return []


def _armar(remitente: str, mail: dict) -> EmailMessage:
    msg = EmailMessage()
    msg["From"] = remitente
    msg["To"] = mail["para"]
    msg["Subject"] = mail["asunto"]
    msg.set_content(mail["texto"])
    return msg
