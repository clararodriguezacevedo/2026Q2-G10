"""Dominio usuarios: el perfil propio y el alta de perfil tras el registro en Cognito."""

from datetime import datetime, timezone

from aws_lambda_powertools import Logger
from aws_lambda_powertools.event_handler.exceptions import BadRequestError

from barriofix import auth, catalogos, dynamo, membresias, serializers
from barriofix.api import crear_app
from barriofix.schemas import RegistroIn

logger = Logger(service="usuarios")
app = crear_app()


@app.get("/api/auth/me")
def me():
    sub = auth.sub(app)
    item = auth.perfil(app)  # 404 si todavia no se completo el registro
    return serializers.usuario_out(sub, item)


@app.post("/api/auth/registro")
def registro(datos: RegistroIn):
    """Crea el perfil en DynamoDB para una cuenta ya registrada en Cognito.
    El sub y el email salen del token validado, nunca del body."""
    sub = auth.sub(app)
    claims = auth.claims(app)

    item = {
        "PK": f"USER#{sub}",
        "SK": "PERFIL",
        "nombre": datos.nombre,
        "apellido": datos.apellido,
        "email": claims.get("email", ""),
        "telefono": datos.telefono or "",
        "rol": datos.rol,
        "fecha_registro": datetime.now(timezone.utc).isoformat(),
    }
    if datos.rol == "PROFESIONAL":
        item["disponible"] = True
        item["descripcion"] = datos.descripcion_profesional or ""
        for tipo, ids in (("CATEGORIA", datos.categorias), ("ZONA", datos.zonas)):
            for valor in ids:
                if catalogos.existe_activo(tipo, valor) is None:
                    raise BadRequestError(f"{tipo.lower()} {valor} inexistente o inactiva")
        if datos.categorias:
            item["categorias"] = set(datos.categorias)
        if datos.zonas:
            item["zonas"] = set(datos.zonas)

    # Perfil y membresias (las del GSI del matcher) en una sola transaccion: o
    # queda el profesional completo, o nada. attribute_not_exists en el perfil
    # hace que reintentar el registro sea seguro
    ops = [{"Put": {"Item": item, "ConditionExpression": "attribute_not_exists(PK)"}}]
    ops += [{"Put": {"Item": m}} for m in membresias.items(sub, item)]
    dynamo.transact(ops)
    return serializers.usuario_out(sub, item), 201


@logger.inject_lambda_context
def handler(event, context):
    return app.resolve(event, context)
