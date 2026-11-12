"""Que avisar y a quien ante cada cambio de una solicitud (funciones puras).

Parte del mismo registro del Stream que analytics y lo traduce con
barriofix.eventos, asi los dos consumidores interpretan igual cada transicion.
Devuelve el destinatario (el sub de Cognito) y el texto; buscar su email es
trabajo de la Lambda notif-cliente.
"""

import unicodedata
from typing import Optional

from barriofix import eventos


def topic_name(sub: str) -> str:
    """Nombre del topic SNS personal de un usuario, derivado de su sub.

    Deterministico: cualquier Lambda sabe a que topic publicarle sin guardar el
    ARN. SNS acepta alfanumerico, guiones y guiones bajos; el sub es un UUID."""
    return f"barriofix-user-{sub}"


def asunto_sns(texto: str) -> str:
    """El Subject de SNS tiene que ser ASCII, sin saltos de linea y < 100 chars.
    Nuestros asuntos tienen tildes (tomo, empezo), asi que las sacamos. El cuerpo
    del mail sigue yendo en UTF-8."""
    ascii_ = unicodedata.normalize("NFKD", texto).encode("ascii", "ignore").decode()
    return ascii_.replace("\n", " ").strip()[:99]


def armar(registro: dict) -> Optional[dict]:
    """{"destinatario", "asunto", "cuerpo"} o None si el cambio no se avisa."""
    evento = eventos.desde_registro_stream(registro)
    if evento is None:
        return None

    nueva = eventos.deserializar(registro["dynamodb"].get("NewImage", {}))
    vieja = eventos.deserializar(registro["dynamodb"].get("OldImage", {}))
    titulo = nueva.get("titulo", "tu solicitud")
    # Al liberar, el profesional ya no esta en la imagen nueva
    pro = _nombre(nueva.get("profesional") or vieja.get("profesional")) or "El profesional"

    tipo = evento["tipo"]
    if tipo == "aceptar":
        return _aviso(evento["id_cliente"], f"{pro} tomó tu solicitud",
                      f"{pro} aceptó \"{titulo}\" y se va a poner en contacto para coordinar.")
    if tipo == "iniciar":
        return _aviso(evento["id_cliente"], f"{pro} empezó el trabajo",
                      f"{pro} empezó a trabajar en \"{titulo}\".")
    if tipo == "resolver":
        return _aviso(evento["id_cliente"], "Tu solicitud quedó resuelta",
                      f"{pro} marcó \"{titulo}\" como resuelta. Cuando puedas, entrá a BarrioFix y "
                      "calificá el trabajo: ayuda a otros vecinos a elegir.")
    if tipo == "liberar":
        return _aviso(evento["id_cliente"], "Tu solicitud vuelve a estar disponible",
                      f"{pro} no va a poder hacer \"{titulo}\". La solicitud volvió a estar disponible "
                      "para otros profesionales; no tenés que hacer nada.")
    if tipo == "cancelar" and evento["id_profesional"]:
        # La cancela el cliente: al que hay que avisar es al profesional asignado
        return _aviso(evento["id_profesional"], "Cancelaron un trabajo que tenías asignado",
                      f"El cliente canceló \"{titulo}\". Ya no tenés que ir.")
    return None


def oportunidad(registro: dict) -> Optional[dict]:
    """Si el cambio deja un trabajo disponible para tomar (se creo o lo liberaron),
    que buscar para avisar a los profesionales que matchean. None si no."""
    evento = eventos.desde_registro_stream(registro)
    if evento is None or evento["tipo"] not in ("creada", "liberar"):
        return None
    nueva = eventos.deserializar(registro["dynamodb"]["NewImage"])
    return {
        "id_solicitud": evento["id_solicitud"],
        "id_categoria": evento["id_categoria"],
        "id_zona": evento["id_zona"],
        "id_urgencia": evento["id_urgencia"],
        "titulo": nueva.get("titulo", "Un trabajo nuevo"),
        "liberada": evento["tipo"] == "liberar",
        # Al que lo acaba de soltar no tiene sentido avisarle
        "excluir": evento["id_profesional"] if evento["tipo"] == "liberar" else None,
    }


def aviso_oportunidad(op: dict, categoria: str, zona: str, urgencia: str) -> dict:
    """Asunto y cuerpo del aviso al profesional (los nombres ya resueltos)."""
    if op["liberada"]:
        asunto = f"Volvió a estar disponible un trabajo de {categoria} en {zona}"
        intro = "Un trabajo que coincide con tus especialidades y zonas volvió a estar disponible"
    else:
        asunto = f"Nuevo trabajo de {categoria} en {zona}"
        intro = "Hay un trabajo nuevo que coincide con tus especialidades y zonas"
    cuerpo = (f"{intro}: \"{op['titulo']}\" (urgencia {urgencia.lower()}). "
              "Entrá a BarrioFix para verlo y tomarlo.")
    return {"asunto": asunto, "cuerpo": cuerpo}


def _aviso(destinatario: Optional[str], asunto: str, cuerpo: str) -> Optional[dict]:
    if not destinatario:
        return None
    return {"destinatario": destinatario, "asunto": asunto, "cuerpo": cuerpo}


def _nombre(persona: Optional[dict]) -> Optional[str]:
    if not persona:
        return None
    return " ".join(p for p in (persona.get("nombre"), persona.get("apellido")) if p) or None
