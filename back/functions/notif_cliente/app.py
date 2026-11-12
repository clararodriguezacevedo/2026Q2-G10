"""Decide a quien avisar ante un cambio de estado y arma el mensaje.

La invoca el topic de eventos (SNS -> Lambda, asincronica). Ya no lee DynamoDB:
el destinatario es el sub que viene en el evento, y su topic SNS personal se
deriva del sub, asi que no necesita el email ni estar en la VPC. DEVUELVE el
aviso, y el destino on-success de la invocacion lo deja en la cola de
notificaciones; de ahi publicar-notificacion publica al topic del usuario.

Si falla tras los reintentos, el destino on-failure lo deja en su DLQ.
"""

import json

from aws_lambda_powertools import Logger

from barriofix import notificaciones

logger = Logger(service="notif-cliente")


@logger.inject_lambda_context
def handler(event, context):
    # SNS invoca con un mensaje por vez: el registro del Stream
    registro = json.loads(event["Records"][0]["Sns"]["Message"])
    aviso = notificaciones.armar(registro)
    if aviso is None:
        return None  # el cambio no se avisa (una foto, una calificacion...)

    return {
        "sub": aviso["destinatario"],
        "asunto": aviso["asunto"],
        "texto": f"{aviso['cuerpo']}\n\nEl equipo de BarrioFix",
    }
