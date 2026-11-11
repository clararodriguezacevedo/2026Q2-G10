# Seed de solicitudes de demo (recuperado del seed que teniamos en RDS).
#
# Arma a mano los items que en runtime crean las Lambdas solicitudes/flujo/
# calificaciones: la META de cada solicitud (con sus claves de GSI) y un item
# por paso de seguimiento. La calificacion vive dentro de la META, igual que en
# el dominio calificaciones. El sub de cada usuario demo sale de Cognito, como
# en perfil_demo (database.tf).
#
# Los datos y la forma salen de seed/solicitudes.json y de los locals
# solicitudes_by_id / seguimientos_seed.

# Momento del primer apply, guardado en el state. timestamp() cambia en cada
# plan; con ignore_changes el output queda fijo, asi las fechas del seed en
# DynamoDB y los eventos de analytics en S3 salen siempre del mismo instante
resource "terraform_data" "seed_ancla" {
  input = timestamp()

  lifecycle {
    ignore_changes = [input]
  }
}

# META de cada solicitud. Atributos de GSI segun el estado:
#   pendiente_categoria (N) solo si esta PENDIENTE  -> indice "pendientes"
#   id_profesional (S) solo si hay profesional      -> indice "por_profesional"
#   id_cliente (S) + id_solicitud (S) siempre        -> indice "por_cliente"
resource "aws_dynamodb_table_item" "solicitud" {
  for_each = local.solicitudes_by_id

  table_name = aws_dynamodb_table.this.name
  hash_key   = aws_dynamodb_table.this.hash_key
  range_key  = aws_dynamodb_table.this.range_key

  item = jsonencode(merge(
    {
      PK             = { S = "SOL#${each.key}" }
      SK             = { S = "META" }
      id_solicitud   = { S = each.key }
      titulo         = { S = each.value.titulo }
      descripcion    = { S = each.value.descripcion }
      direccion      = { S = each.value.direccion }
      fecha_creacion = { S = each.value.fecha_creacion }
      id_categoria   = { N = tostring(each.value.id_categoria) }
      id_urgencia    = { N = tostring(each.value.id_urgencia) }
      id_zona        = { N = tostring(each.value.id_zona) }
      estado         = { S = each.value.estado }
      id_cliente     = { S = aws_cognito_user.demo[each.value.cliente].sub }
      cliente = { M = {
        nombre   = { S = local.demo_users[each.value.cliente].nombre }
        apellido = { S = local.demo_users[each.value.cliente].apellido }
      } }
      cancelada_por_cliente = { BOOL = each.value.cancelada_por_cliente }
      # Mapa vacio: foto_subida hace SET fotos.<id> y necesita el padre
      fotos = { M = {} }
    },
    # Pin del mapa, solo si el seed lo trae
    { for k in(try(each.value.lat, null) != null ? ["lat", "lng"] : []) : k => { N = tostring(each.value[k]) } },
    # Entra al GSI de pendientes solo mientras esta PENDIENTE
    { for k in(each.value.estado == "PENDIENTE" ? ["pendiente_categoria"] : []) : k => { N = tostring(each.value.id_categoria) } },
    # Profesional asignado (tambien lo deja en el GSI por_profesional)
    { for k in(each.value.profesional != null ? ["id_profesional"] : []) : k => { S = aws_cognito_user.demo[each.value.profesional].sub } },
    { for k in(each.value.profesional != null ? ["profesional"] : []) : k => { M = {
      id_usuario = { S = aws_cognito_user.demo[each.value.profesional].sub }
      nombre     = { S = local.demo_users[each.value.profesional].nombre }
      apellido   = { S = local.demo_users[each.value.profesional].apellido }
    } } },
    # Fecha de cancelacion del cliente, solo si la cancelo
    { for k in(each.value.cancelada_por_cliente ? ["fecha_cancelacion_cliente"] : []) : k => { S = timeadd(each.value.fecha_creacion, "${each.value.cancelada_offset_horas}h") } },
    # Calificacion embebida, solo en las resueltas calificadas
    { for k in(each.value.calificacion != null ? ["calificacion"] : []) : k => { M = {
      id_calificacion    = { S = each.key }
      puntuacion         = { N = tostring(each.value.calificacion.puntuacion) }
      comentario         = { S = each.value.calificacion.comentario }
      fecha_calificacion = { S = timeadd(each.value.fecha_creacion, "${each.value.calificacion.offset_horas}h") }
    } } },
  ))

  lifecycle {
    # Si alguien opera la solicitud desde la app, no la pisamos en el proximo apply
    ignore_changes = [item]
  }
}

# Un item por paso de seguimiento. No llevan atributos de GSI, asi que no entran
# en ningun indice (igual que en runtime: solo la META los tiene).
resource "aws_dynamodb_table_item" "seguimiento" {
  for_each = local.seguimientos_seed

  table_name = aws_dynamodb_table.this.name
  hash_key   = aws_dynamodb_table.this.hash_key
  range_key  = aws_dynamodb_table.this.range_key

  item = jsonencode(merge(
    {
      PK          = { S = "SOL#${each.value.id_solicitud}" }
      SK          = { S = each.value.sk }
      estado      = { S = each.value.estado }
      fecha_desde = { S = each.value.fecha_desde }
      actor = { M = {
        id_usuario = { S = aws_cognito_user.demo[each.value.actor].sub }
        nombre     = { S = local.demo_users[each.value.actor].nombre }
        apellido   = { S = local.demo_users[each.value.actor].apellido }
      } }
    },
    # profesional del paso (lo setean aceptar/iniciar/resolver, no liberar/cancelar)
    { for k in(each.value.profesional != null ? ["profesional"] : []) : k => { M = {
      id_usuario = { S = aws_cognito_user.demo[each.value.profesional].sub }
      nombre     = { S = local.demo_users[each.value.profesional].nombre }
      apellido   = { S = local.demo_users[each.value.profesional].apellido }
    } } },
    { for k in(each.value.motivo != null ? ["motivo"] : []) : k => { S = each.value.motivo } },
  ))

  lifecycle {
    ignore_changes = [item]
  }
}
