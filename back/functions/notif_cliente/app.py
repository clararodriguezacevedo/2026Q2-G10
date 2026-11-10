"""Decide a quien avisar por mail ante un cambio de estado, y le arma el mensaje.

La invoca el topic de eventos (SNS -> Lambda, asincronica). Va dentro de la VPC
porque lee el email del perfil en DynamoDB. No manda el mail ni lo encola: lo
DEVUELVE, y el destino on-success de la invocacion (configurado en Terraform)
deja ese resultado en la cola email. Asi no necesita salir de la VPC, ya que
SQS no tiene Gateway Endpoint; la entrega al destino la hace el servicio Lambda.

Si falla despues de los reintentos, el destino on-failure lo deja en su DLQ.
"""

import json

from aws_lambda_powertools import Logger

from barriofix import dynamo, notificaciones

logger = Logger(service="notif-cliente")


@logger.inject_lambda_context
def handler(event, context):
    # SNS invoca con un mensaje por vez: el registro del Stream
    registro = json.loads(event["Records"][0]["Sns"]["Message"])
    aviso = notificaciones.armar(registro)
    if aviso is None:
        return None  # el cambio no se avisa (una foto, una calificacion...)

    perfil = dynamo.get_item(f"USER#{aviso['destinatario']}", "PERFIL")
    if not perfil or not perfil.get("email"):
        logger.warning("destinatario sin perfil o sin email", extra={"sub": aviso["destinatario"]})
        return None

    nombre = perfil.get("nombre", "")
    return {
        "para": perfil["email"],
        "asunto": aviso["asunto"],
        "texto": f"Hola {nombre},\n\n{aviso['cuerpo']}\n\nEl equipo de BarrioFix",
    }
