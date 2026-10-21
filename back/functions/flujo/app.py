"""Dominio flujo: las transiciones de estado de una solicitud.

Cada transicion es una TransactWriteItems: un Update condicional sobre la META
(la condicion sobre `estado` resuelve la concurrencia, p. ej. dos profesionales
aceptando a la vez) mas un Put del paso de seguimiento. El permiso va dentro de
la condicion, no en un if previo, para que no haya ventana entre leer y escribir.
"""

from datetime import datetime, timezone

from aws_lambda_powertools import Logger
from aws_lambda_powertools.event_handler.exceptions import NotFoundError, ServiceError

from barriofix import auth, dynamo, reglas, serializers
from barriofix.api import crear_app
from barriofix.ids import ulid
from barriofix.schemas import TransicionIn

logger = Logger(service="flujo")
app = crear_app()


@app.post("/api/solicitudes/<id_sol>/aceptar")
def aceptar(id_sol: str, datos: TransicionIn):
    sub, perfil = _profesional()
    # Un profesional puede tomar cualquier trabajo pendiente, sea o no de sus
    # categorias. Solo validamos que exista (404), la condicion atomica sobre el
    # estado resuelve la concurrencia
    _meta(id_sol)

    quien = {"id_usuario": sub, "nombre": perfil["nombre"], "apellido": perfil["apellido"]}
    return _aplicar(
        id_sol, reglas.ASIGNADO, quien, datos.motivo,
        update="SET estado = :e, id_profesional = :p, profesional = :pm REMOVE pendiente_categoria",
        condition="estado = :pend",
        values={":e": reglas.ASIGNADO, ":p": sub, ":pm": quien, ":pend": reglas.PENDIENTE},
        profesional=quien,
    )


@app.post("/api/solicitudes/<id_sol>/iniciar")
def iniciar(id_sol: str, datos: TransicionIn):
    sub, perfil = _profesional()
    return _aplicar(
        id_sol, reglas.EN_PROGRESO, _quien(sub, perfil), datos.motivo,
        update="SET estado = :e",
        condition="estado = :a AND id_profesional = :sub",
        values={":e": reglas.EN_PROGRESO, ":a": reglas.ASIGNADO, ":sub": sub},
        profesional=_quien(sub, perfil),
    )


@app.post("/api/solicitudes/<id_sol>/resolver")
def resolver(id_sol: str, datos: TransicionIn):
    sub, perfil = _profesional()
    return _aplicar(
        id_sol, reglas.RESUELTO, _quien(sub, perfil), datos.motivo,
        update="SET estado = :e",
        condition="estado = :p AND id_profesional = :sub",
        values={":e": reglas.RESUELTO, ":p": reglas.EN_PROGRESO, ":sub": sub},
        profesional=_quien(sub, perfil),
    )


@app.post("/api/solicitudes/<id_sol>/liberar")
def liberar(id_sol: str, datos: TransicionIn):
    sub, perfil = _profesional()
    meta = _meta(id_sol)
    return _aplicar(
        id_sol, reglas.PENDIENTE, _quien(sub, perfil), datos.motivo,
        update="SET estado = :e, pendiente_categoria = :cat REMOVE id_profesional, profesional",
        condition="estado IN (:a, :p) AND id_profesional = :sub",
        values={":e": reglas.PENDIENTE, ":cat": int(meta["id_categoria"]),
                ":a": reglas.ASIGNADO, ":p": reglas.EN_PROGRESO, ":sub": sub},
        profesional=None,
    )


@app.post("/api/solicitudes/<id_sol>/cancelar")
def cancelar(id_sol: str, datos: TransicionIn):
    sub = auth.sub(app)
    perfil = auth.perfil(app)
    ahora = _ahora()
    return _aplicar(
        id_sol, reglas.CANCELADO, _quien(sub, perfil), datos.motivo,
        update="SET estado = :e, cancelada_por_cliente = :true, fecha_cancelacion_cliente = :f REMOVE pendiente_categoria",
        condition="estado IN (:pend, :a, :p) AND id_cliente = :sub",
        values={":e": reglas.CANCELADO, ":true": True, ":f": ahora, ":sub": sub,
                ":pend": reglas.PENDIENTE, ":a": reglas.ASIGNADO, ":p": reglas.EN_PROGRESO},
        profesional=None,
    )


# helpers

def _aplicar(id_sol, estado_destino, actor, motivo, update, condition, values, profesional):
    ahora = _ahora()
    seg = {
        "PK": f"SOL#{id_sol}", "SK": f"SEG#{ulid()}",
        "estado": estado_destino,
        "actor": actor,
        "fecha_desde": ahora,
    }
    if profesional:
        seg["profesional"] = profesional
    if motivo:
        seg["motivo"] = motivo

    # Dejamos la fecha de ultima modificacion en la META junto con el cambio de
    # estado (mismo instante que el paso de seguimiento). Todas las update
    # arrancan con "SET ", asi que inyectamos ahi la asignacion.
    update = update.replace("SET ", "SET fecha_actualizacion = :__fa, ", 1)
    values = {**values, ":__fa": ahora}

    dynamo.transact([
        {"Update": {
            "Key": {"PK": f"SOL#{id_sol}", "SK": "META"},
            "UpdateExpression": update,
            "ConditionExpression": condition,
            "ExpressionAttributeValues": values,
        }},
        {"Put": {"Item": seg}},
    ])

    meta = dynamo.get_item(f"SOL#{id_sol}", "META")
    return serializers.solicitud_out(meta)


def _meta(id_sol: str) -> dict:
    meta = dynamo.get_item(f"SOL#{id_sol}", "META")
    if meta is None:
        raise NotFoundError("Solicitud no encontrada")
    return meta


def _profesional():
    sub = auth.sub(app)
    perfil = auth.perfil(app)
    if perfil.get("rol") != "PROFESIONAL":
        raise ServiceError(403, "Solo un profesional puede hacer esta accion")
    return sub, perfil


def _quien(sub, perfil):
    return {"id_usuario": sub, "nombre": perfil["nombre"], "apellido": perfil["apellido"]}


def _ahora() -> str:
    return datetime.now(timezone.utc).isoformat()


@logger.inject_lambda_context
def handler(event, context):
    return app.resolve(event, context)
