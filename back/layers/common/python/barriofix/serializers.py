"""Arma las respuestas con la forma que ya consume el front.

El estado se devuelve como objeto {"nombre": ...} para no romper los usos tipo
`solicitud.estado.nombre`. Categoria, zona y urgencia salen del cache de catalogos.
"""

from typing import Optional

from barriofix import catalogos, media


def usuario_out(sub: str, item: dict) -> dict:
    rol = item.get("rol", "CLIENTE")
    return {
        "id_usuario": sub,
        "nombre": item["nombre"],
        "apellido": item["apellido"],
        "email": item.get("email"),
        "telefono": item.get("telefono"),
        "fecha_registro": item.get("fecha_registro"),
        "es_cliente": rol == "CLIENTE",
        "es_profesional": rol == "PROFESIONAL",
        "es_admin": False,
        "activo": True,
    }


def _breve(id_usuario: Optional[str], datos: Optional[dict]) -> Optional[dict]:
    if not id_usuario:
        return None
    datos = datos or {}
    return {
        "id_usuario": id_usuario,
        "nombre": datos.get("nombre"),
        "apellido": datos.get("apellido"),
    }


def solicitud_out(item: dict) -> dict:
    return {
        "id_solicitud": item["id_solicitud"],
        "titulo": item["titulo"],
        "descripcion": item["descripcion"],
        "direccion": item["direccion"],
        "lat": float(item["lat"]) if "lat" in item else None,
        "lng": float(item["lng"]) if "lng" in item else None,
        "fecha_creacion": item["fecha_creacion"],
        # Ultima modificacion: se stampea en cada cambio de estado. Para items
        # viejos (sin el campo) caemos a la fecha de creacion.
        "fecha_actualizacion": item.get("fecha_actualizacion") or item["fecha_creacion"],
        "cancelada_por_cliente": bool(item.get("cancelada_por_cliente", False)),
        "fecha_cancelacion_cliente": item.get("fecha_cancelacion_cliente"),
        "categoria": catalogos.por_id("CATEGORIA", int(item["id_categoria"])),
        "urgencia": catalogos.por_id("URGENCIA", int(item["id_urgencia"])),
        "zona": catalogos.por_id("ZONA", int(item["id_zona"])),
        "cliente": _breve(item.get("id_cliente"), item.get("cliente")),
        "estado": {"nombre": item["estado"]},
        "profesional": _breve(item.get("id_profesional"), item.get("profesional")),
        "calificacion": item.get("calificacion"),
        "fotos": [foto_out(f) for f in item.get("fotos", {}).values()],
    }


def foto_out(foto: dict) -> dict:
    """Agrega una URL prefirmada temporal para ver la foto directo de S3."""
    return {
        "id_foto": foto.get("id_foto"),
        "tipo_foto": foto.get("tipo_foto"),
        "nombre_archivo": foto.get("nombre_archivo"),
        "fecha_subida": foto.get("fecha_subida"),
        "url": media.presigned_get(foto["s3_key"]) if foto.get("s3_key") else None,
    }


def seguimiento_out(segs: list[dict]) -> list[dict]:
    """Los pasos ordenados por SK ascendente. fecha_hasta se calcula como la
    fecha_desde del paso siguiente (los SEG# son inmutables)."""
    ordenados = sorted(segs, key=lambda s: s["SK"])
    salida = []
    for i, s in enumerate(ordenados):
        hasta = ordenados[i + 1]["fecha_desde"] if i + 1 < len(ordenados) else None
        salida.append({
            "id_seguimiento": s["SK"],
            "estado": {"nombre": s["estado"]},
            "profesional": s.get("profesional"),
            "actor": s.get("actor"),
            "fecha_desde": s["fecha_desde"],
            "fecha_hasta": hasta,
            "motivo": s.get("motivo"),
        })
    return salida
