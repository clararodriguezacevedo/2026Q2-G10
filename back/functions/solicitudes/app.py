"""Dominio solicitudes: crear, listar (paginado), ver una y su seguimiento.

Las transiciones de estado (aceptar, iniciar, etc.) viven en el dominio flujo.
"""

from datetime import datetime, timezone
from decimal import Decimal

from aws_lambda_powertools import Logger
from aws_lambda_powertools.event_handler.exceptions import (
    BadRequestError,
    NotFoundError,
    ServiceError,
)

from barriofix import auth, catalogos, dynamo, reglas, serializers
from barriofix.api import crear_app
from barriofix.ids import ulid
from barriofix.schemas import SolicitudIn

logger = Logger(service="solicitudes")
app = crear_app()


@app.get("/api/solicitudes")
def listar():
    sub = auth.sub(app)
    perfil = auth.perfil(app)
    limit = int(app.current_event.get_query_string_value("limit", "50"))
    cursor = app.current_event.get_query_string_value("cursor", None)

    if perfil.get("rol") == "PROFESIONAL":
        items, siguiente = dynamo.query_index("por_profesional", "id_profesional", sub,
                                              limit=limit, cursor=cursor)
    else:
        items, siguiente = dynamo.query_index("por_cliente", "id_cliente", sub,
                                              limit=limit, cursor=cursor)

    return {"items": [serializers.solicitud_out(i) for i in items], "cursor": siguiente}


@app.get("/api/trabajos")
def trabajos():
    """Trabajos PENDIENTE que un profesional puede tomar: por cada una de sus
    categorias, una query al GSI sparse de pendientes. Zona y urgencia como
    filtro. Tope de 100 (sin paginar: el indice de pendientes es chico)."""
    sub = auth.sub(app)
    perfil = auth.perfil(app)
    if perfil.get("rol") != "PROFESIONAL":
        raise ServiceError(403, "Solo un profesional ve trabajos disponibles")

    todas = app.current_event.get_query_string_value("todas_las_categorias", "false") == "true"
    id_zona = app.current_event.get_query_string_value("id_zona", None)
    id_urgencia = app.current_event.get_query_string_value("id_urgencia", None)

    if todas:
        cats = [c["id_categoria"] for c in catalogos.listar("CATEGORIA")]
    else:
        cats = [int(c) for c in perfil.get("categorias", [])]

    items: list[dict] = []
    for c in cats:
        got, _ = dynamo.query_index("pendientes", "pendiente_categoria", c, limit=100)
        items.extend(got)

    if id_zona:
        items = [i for i in items if int(i["id_zona"]) == int(id_zona)]
    if id_urgencia:
        items = [i for i in items if int(i["id_urgencia"]) == int(id_urgencia)]

    items.sort(key=lambda i: i["id_solicitud"], reverse=True)
    return {"items": [serializers.solicitud_out(i) for i in items[:100]], "cursor": None}


@app.post("/api/solicitudes")
def crear(datos: SolicitudIn):
    sub = auth.sub(app)
    perfil = auth.perfil(app)
    if perfil.get("rol") != "CLIENTE":
        raise ServiceError(403, "Solo un cliente puede crear solicitudes")

    # Los catalogos tienen que existir y estar activos
    for tipo, valor in (("CATEGORIA", datos.id_categoria), ("URGENCIA", datos.id_urgencia), ("ZONA", datos.id_zona)):
        if catalogos.existe_activo(tipo, valor) is None:
            raise BadRequestError(f"{tipo.lower()} {valor} inexistente o inactiva")

    id_sol = ulid()
    ahora = datetime.now(timezone.utc).isoformat()
    cliente = {"nombre": perfil["nombre"], "apellido": perfil["apellido"]}

    meta = {
        "PK": f"SOL#{id_sol}", "SK": "META",
        "id_solicitud": id_sol,
        "titulo": datos.titulo, "descripcion": datos.descripcion, "direccion": datos.direccion,
        "fecha_creacion": ahora,
        "fecha_actualizacion": ahora,
        "id_categoria": datos.id_categoria, "id_urgencia": datos.id_urgencia, "id_zona": datos.id_zona,
        "estado": reglas.PENDIENTE,
        "id_cliente": sub, "cliente": cliente,
        "pendiente_categoria": datos.id_categoria,  # entra al GSI de pendientes
        "cancelada_por_cliente": False,
        "fotos": {},  # mapa vacio: foto_subida hace SET fotos.<id> y necesita el padre
    }
    if datos.lat is not None:
        # DynamoDB no acepta float, va como Decimal
        meta["lat"] = Decimal(str(datos.lat))
        meta["lng"] = Decimal(str(datos.lng))
    seg = {
        "PK": f"SOL#{id_sol}", "SK": f"SEG#{ulid()}",
        "estado": reglas.PENDIENTE,
        "actor": {"id_usuario": sub, **cliente},
        "fecha_desde": ahora,
    }

    dynamo.transact([
        {"Put": {"Item": meta, "ConditionExpression": "attribute_not_exists(PK)"}},
        {"Put": {"Item": seg}},
    ])
    return serializers.solicitud_out(meta), 201


@app.get("/api/solicitudes/<id_sol>")
def obtener(id_sol: str):
    meta = _meta_visible(id_sol)
    return serializers.solicitud_out(meta)


@app.get("/api/solicitudes/<id_sol>/seguimiento")
def seguimiento(id_sol: str):
    _meta_visible(id_sol)
    segs = dynamo.query_collection(f"SOL#{id_sol}", "SEG#")
    return serializers.seguimiento_out(segs)


def _meta_visible(id_sol: str) -> dict:
    """La META si el usuario puede verla: el cliente dueño, el profesional
    asignado, o cualquier profesional si esta PENDIENTE (tablero de trabajos)."""
    meta = dynamo.get_item(f"SOL#{id_sol}", "META")
    if meta is None:
        raise NotFoundError("Solicitud no encontrada")

    sub = auth.sub(app)
    perfil = auth.perfil(app)
    es_mia = meta.get("id_cliente") == sub or meta.get("id_profesional") == sub
    disponible = perfil.get("rol") == "PROFESIONAL" and meta.get("estado") == reglas.PENDIENTE
    if not (es_mia or disponible):
        raise ServiceError(403, "La solicitud es de otro usuario")
    return meta


@logger.inject_lambda_context
def handler(event, context):
    return app.resolve(event, context)
