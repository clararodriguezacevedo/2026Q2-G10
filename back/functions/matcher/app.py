"""Avisa a los profesionales que matchean cuando un trabajo queda disponible.

La invoca el topic de eventos (SNS -> Lambda) con una filter policy que solo deja
pasar solicitudes en PENDIENTE: las recien creadas y las que alguien libero.
Busca los profesionales disponibles de esa categoria que cubren esa zona con una
Query al GSI profesionales_por_categoria (sin Scan) y arma un mail para cada uno.

Igual que notif-cliente: esta en la VPC y no encola, DEVUELVE la lista de mails y
el destino on-success de la invocacion la deja en la cola de notificaciones. Asi
publicar el aviso en SNS queda en publicar-notificacion, la unica fuera de la VPC.
"""

import json

from aws_lambda_powertools import Logger

from barriofix import catalogos, dynamo, notificaciones

logger = Logger(service="matcher")

# Tope de avisos por trabajo: el registro del destino no puede pasar de 256 KB
MAX_AVISOS = 50


@logger.inject_lambda_context
def handler(event, context):
    registro = json.loads(event["Records"][0]["Sns"]["Message"])
    op = notificaciones.oportunidad(registro)
    if op is None:
        return None  # un cambio sobre una pendiente que no la vuelve a ofrecer (una foto)

    candidatos = [p for p in dynamo.profesionales_para(op["id_categoria"], op["id_zona"])
                  if p["id_usuario"] != op["excluir"]]
    logger.info("profesionales que matchean", extra={
        "id_solicitud": op["id_solicitud"], "candidatos": len(candidatos)})
    if not candidatos:
        return None  # un desierto de oferta: nadie cubre esa categoria en esa zona

    aviso = notificaciones.aviso_oportunidad(
        op,
        categoria=_nombre("CATEGORIA", op["id_categoria"]),
        zona=_nombre("ZONA", op["id_zona"]),
        urgencia=_nombre("URGENCIA", op["id_urgencia"]),
    )
    return [
        {"sub": p["id_usuario"], "asunto": aviso["asunto"],
         "texto": f"Hola {p['nombre']},\n\n{aviso['cuerpo']}\n\nEl equipo de BarrioFix"}
        for p in candidatos[:MAX_AVISOS]
    ]


def _nombre(tipo: str, id_valor) -> str:
    item = catalogos.por_id(tipo, int(id_valor)) if id_valor is not None else None
    return item["nombre"] if item else "-"
