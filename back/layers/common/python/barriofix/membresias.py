"""Items de membresia: un item por profesional y categoria que ofrece.

El perfil guarda las categorias como un set, y DynamoDB no puede indexar un
valor que esta adentro de un set. Por eso se escribe ademas un item chico por
categoria, con la categoria en un atributo propio (pro_categoria) que es la
clave del GSI profesionales_por_categoria. Asi "los plomeros" es una sola Query,
sin Scan. Las zonas van como set y se filtran despues (son pocas por profesional).

Llevan copiados el nombre y el email para que el matcher no tenga que leer el
perfil de cada uno (los perfiles no se editan en este alcance).
"""

PREFIJO = "PROCAT#"


def items(sub: str, perfil: dict) -> list[dict]:
    """Items de membresia de un perfil de profesional (lista vacia si no es)."""
    if perfil.get("rol") != "PROFESIONAL":
        return []
    salida = []
    for categoria in sorted(perfil.get("categorias") or []):
        item = {
            "PK": f"USER#{sub}",
            "SK": f"{PREFIJO}{int(categoria):04d}",
            "pro_categoria": int(categoria),
            "id_usuario": sub,
            "nombre": perfil["nombre"],
            "apellido": perfil["apellido"],
            "email": perfil.get("email", ""),
            "disponible": perfil.get("disponible", True),
        }
        # DynamoDB no acepta sets vacios: sin zonas, el atributo no va
        if perfil.get("zonas"):
            item["zonas"] = set(int(z) for z in perfil["zonas"])
        salida.append(item)
    return salida
