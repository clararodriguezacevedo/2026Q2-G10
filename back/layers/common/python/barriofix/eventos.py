"""Eventos de negocio derivados del DynamoDB Stream (funciones puras, sin AWS).

Nadie publica eventos a mano: el Stream captura cada escritura de la META de una
solicitud y aca se traduce ese registro (imagen vieja y nueva) a un evento plano,
por ejemplo "aceptar" o "cancelar". Lo usan los consumidores del topic de eventos
(analytics hoy; notif-cliente y matcher despues), asi todos interpretan el
cambio de la misma forma.
"""

from datetime import datetime, timezone
from decimal import Decimal
from typing import Any, Optional

from barriofix import reglas

CREADA = "creada"
CALIFICADA = "calificada"

# (estado anterior, estado nuevo) -> nombre de la transicion
_TRANSICIONES = {
    (reglas.PENDIENTE, reglas.ASIGNADO): "aceptar",
    (reglas.ASIGNADO, reglas.EN_PROGRESO): "iniciar",
    (reglas.EN_PROGRESO, reglas.RESUELTO): "resolver",
    (reglas.ASIGNADO, reglas.PENDIENTE): "liberar",
    (reglas.EN_PROGRESO, reglas.PENDIENTE): "liberar",
}


def desde_registro_stream(registro: dict) -> Optional[dict]:
    """Evento plano a partir de un registro del Stream, o None si el cambio no
    es un evento de negocio (por ejemplo, se agrego una foto)."""
    dynamo = registro["dynamodb"]
    nueva = deserializar(dynamo.get("NewImage", {}))
    vieja = deserializar(dynamo.get("OldImage", {}))
    if not nueva:
        return None

    tipo, ts = _tipo_y_momento(registro["eventName"], vieja, nueva)
    if tipo is None:
        return None

    return {
        "event_id": registro["eventID"],
        "tipo": tipo,
        "ts": ts or _iso(dynamo.get("ApproximateCreationDateTime")),
        "id_solicitud": nueva["id_solicitud"],
        "estado_anterior": vieja.get("estado"),
        "estado_nuevo": nueva["estado"],
        "id_categoria": nueva.get("id_categoria"),
        "id_zona": nueva.get("id_zona"),
        "id_urgencia": nueva.get("id_urgencia"),
        "id_cliente": nueva.get("id_cliente"),
        # Al liberar o cancelar, el profesional ya no esta en la imagen nueva:
        # es el de la vieja, y es el dato que importa (quien solto el trabajo)
        "id_profesional": nueva.get("id_profesional") or vieja.get("id_profesional"),
        "fecha_creacion": nueva.get("fecha_creacion"),
        "puntuacion": (nueva.get("calificacion") or {}).get("puntuacion") if tipo == CALIFICADA else None,
    }


def _tipo_y_momento(event_name: str, vieja: dict, nueva: dict) -> tuple[Optional[str], Optional[str]]:
    if event_name == "INSERT":
        return CREADA, nueva.get("fecha_creacion")

    antes, ahora = vieja.get("estado"), nueva.get("estado")
    if antes != ahora:
        if ahora == reglas.CANCELADO:
            tipo = "cancelar"
        else:
            tipo = _TRANSICIONES.get((antes, ahora), "cambio_estado")
        return tipo, nueva.get("fecha_actualizacion")

    if "calificacion" in nueva and "calificacion" not in vieja:
        return CALIFICADA, nueva["calificacion"].get("fecha_calificacion")

    return None, None


def deserializar(imagen: dict) -> dict:
    """Imagen en DynamoDB JSON ({"estado": {"S": "PENDIENTE"}}) a tipos de Python."""
    return {k: _valor(v) for k, v in imagen.items()}


def _valor(attr: dict) -> Any:
    (tipo, valor), = attr.items()
    if tipo == "S":
        return valor
    if tipo == "N":
        return _numero(valor)
    if tipo == "BOOL":
        return valor
    if tipo == "NULL":
        return None
    if tipo == "M":
        return deserializar(valor)
    if tipo == "L":
        return [_valor(v) for v in valor]
    if tipo == "SS":
        return list(valor)
    if tipo == "NS":
        return [_numero(v) for v in valor]
    # B y BS no aparecen en nuestra tabla
    return valor


def _numero(texto: str) -> Any:
    d = Decimal(texto)
    return int(d) if d == d.to_integral_value() else float(d)


def _iso(epoch: Any) -> Optional[str]:
    if epoch is None:
        return None
    return datetime.fromtimestamp(float(epoch), tz=timezone.utc).isoformat()
