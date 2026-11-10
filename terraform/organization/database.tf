# Tabla unica con cuatro GSIs sparse
#   por_cliente                 -> solicitudes de un cliente
#   por_profesional             -> solicitudes asignadas a un profesional (sparse)
#   pendientes                  -> trabajos disponibles por categoria (sparse)
#   profesionales_por_categoria -> profesionales de una categoria, para el matcher (sparse)

# Sin CMK propia ni point in time recovery, decisiones asumidas (ver docs/arquitectura.md)
#tfsec:ignore:aws-dynamodb-table-customer-key
#tfsec:ignore:aws-dynamodb-enable-recovery
resource "aws_dynamodb_table" "this" {
  name         = var.project
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # Solo se declaran los atributos que son clave de la tabla o de un indice
  attribute {
    name = "PK"
    type = "S"
  }
  attribute {
    name = "SK"
    type = "S"
  }
  attribute {
    name = "id_cliente"
    type = "S"
  }
  attribute {
    name = "id_profesional"
    type = "S"
  }
  attribute {
    name = "pendiente_categoria"
    type = "N"
  }
  attribute {
    name = "id_solicitud"
    type = "S"
  }
  attribute {
    name = "pro_categoria"
    type = "N"
  }

  global_secondary_index {
    name            = "por_cliente"
    projection_type = "ALL"

    key_schema {
      attribute_name = "id_cliente"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "id_solicitud"
      key_type       = "RANGE"
    }
  }

  global_secondary_index {
    name            = "por_profesional"
    projection_type = "ALL"

    key_schema {
      attribute_name = "id_profesional"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "id_solicitud"
      key_type       = "RANGE"
    }
  }

  global_secondary_index {
    name            = "pendientes"
    projection_type = "ALL"

    key_schema {
      attribute_name = "pendiente_categoria"
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = "id_solicitud"
      key_type       = "RANGE"
    }
  }

  # Solo tienen pro_categoria los items de membresia (USER#<sub> / PROCAT#<cat>):
  # un item por profesional y categoria, porque no se puede indexar un valor
  # adentro del set de categorias del perfil. Sin clave de rango: el matcher
  # trae todos los de la categoria y filtra por zona y disponibilidad
  global_secondary_index {
    name            = "profesionales_por_categoria"
    projection_type = "ALL"

    key_schema {
      attribute_name = "pro_categoria"
      key_type       = "HASH"
    }
  }

  # Cifrado en reposo con la llave gestionada por AWS (no CMK propia)
  server_side_encryption {
    enabled = true
  }

  # Fuente del backbone de eventos (ver eventos.tf). Con la imagen vieja y la
  # nueva se sabe que transicion hubo y quien estaba asignado antes de liberar
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # Desactivada a proposito para que terraform destroy pueda borrar la tabla
  deletion_protection_enabled = false

  tags = local.tags
}

# Restringe el acceso de datos al endpoint de la VPC, opcional via variable
resource "aws_dynamodb_resource_policy" "vpc_only" {
  count = var.restrict_dynamodb_to_vpc ? 1 : 0

  resource_arn = aws_dynamodb_table.this.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "SoloDesdeLaVpc"
      Effect    = "Deny"
      Principal = "*"
      Action = [
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "dynamodb:UpdateItem",
        "dynamodb:DeleteItem",
        "dynamodb:Query",
        "dynamodb:BatchGetItem",
        "dynamodb:TransactWriteItems",
      ]
      Resource = [
        aws_dynamodb_table.this.arn,
        "${aws_dynamodb_table.this.arn}/index/*",
      ]
      Condition = {
        StringNotEquals = { "aws:SourceVpce" = aws_vpc_endpoint.dynamodb.id }
      }
    }]
  })
}

# Seed de catalogos

resource "aws_dynamodb_table_item" "catalogo" {
  for_each = local.seed_items

  table_name = aws_dynamodb_table.this.name
  hash_key   = aws_dynamodb_table.this.hash_key
  range_key  = aws_dynamodb_table.this.range_key

  item = jsonencode(merge(
    {
      PK          = { S = "CATALOGO" }
      SK          = { S = each.key }
      id          = { N = tostring(each.value.id) }
      nombre      = { S = each.value.nombre }
      activo      = { BOOL = true }
      descripcion = { S = try(each.value.descripcion, "") }
    },
    # La urgencia lleva orden de prioridad
    { for k in(each.value.tipo == "urgencia" ? ["orden_prioridad"] : []) : k => { N = tostring(try(each.value.orden_prioridad, 0)) } }
  ))

  lifecycle {
    # Si alguien edita un catalogo desde la app, no lo pisamos en el proximo apply
    ignore_changes = [item]
  }
}

# perfiles de demo

resource "aws_dynamodb_table_item" "perfil_demo" {
  for_each = aws_cognito_user.demo

  table_name = aws_dynamodb_table.this.name
  hash_key   = aws_dynamodb_table.this.hash_key
  range_key  = aws_dynamodb_table.this.range_key

  item = jsonencode(merge(
    {
      PK       = { S = "USER#${each.value.sub}" }
      SK       = { S = "PERFIL" }
      nombre   = { S = local.demo_users[each.key].nombre }
      apellido = { S = local.demo_users[each.key].apellido }
      email    = { S = local.demo_users[each.key].email }
      telefono = { S = local.demo_users[each.key].telefono }
      rol      = { S = local.demo_users[each.key].rol }
    },
    # Atributos solo de profesional
    { for k in(local.demo_users[each.key].rol == "PROFESIONAL" ? ["disponible"] : []) : k => { BOOL = true } },
    { for k in(local.demo_users[each.key].rol == "PROFESIONAL" ? ["descripcion"] : []) : k => { S = local.demo_users[each.key].descripcion } },
    { for k in(local.demo_users[each.key].rol == "PROFESIONAL" ? ["categorias"] : []) : k => { NS = [for c in local.demo_users[each.key].categorias : tostring(c)] } },
    { for k in(local.demo_users[each.key].rol == "PROFESIONAL" ? ["zonas"] : []) : k => { NS = [for z in local.demo_users[each.key].zonas : tostring(z)] } },
  ))

  lifecycle {
    ignore_changes = [item]
  }
}

# Membresias de los profesionales de demo: lo mismo que escribe el registro
# (barriofix/membresias.py), un item por profesional y categoria para el GSI
resource "aws_dynamodb_table_item" "membresia_demo" {
  for_each = local.demo_membresias

  table_name = aws_dynamodb_table.this.name
  hash_key   = aws_dynamodb_table.this.hash_key
  range_key  = aws_dynamodb_table.this.range_key

  item = jsonencode({
    PK            = { S = "USER#${aws_cognito_user.demo[each.value.usuario].sub}" }
    SK            = { S = format("PROCAT#%04d", each.value.categoria) }
    pro_categoria = { N = tostring(each.value.categoria) }
    id_usuario    = { S = aws_cognito_user.demo[each.value.usuario].sub }
    nombre        = { S = local.demo_users[each.value.usuario].nombre }
    apellido      = { S = local.demo_users[each.value.usuario].apellido }
    email         = { S = local.demo_users[each.value.usuario].email }
    disponible    = { BOOL = true }
    zonas         = { NS = [for z in local.demo_users[each.value.usuario].zonas : tostring(z)] }
  })

  lifecycle {
    ignore_changes = [item]
  }
}
