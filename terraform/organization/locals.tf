locals {
  account_id = data.aws_caller_identity.this.account_id

  # Sufijo de cuenta para los nombres que tienen que ser unicos en todo AWS
  suffix = local.account_id

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }

  # Nombres de los buckets, unicos globalmente
  bucket_front     = format("%s-frontend-%s", var.project, local.suffix)
  bucket_media     = format("%s-media-%s", var.project, local.suffix)
  bucket_analytics = format("%s-analytics-%s", var.project, local.suffix)

  # Del Stream solo interesa la META de las solicitudes al crearse o cambiar.
  # Deja afuera los pasos SEG#, los perfiles, los catalogos y los borrados.
  # Lo comparten el Pipe y, si se usa, el event source mapping del publicador
  filtro_eventos = jsonencode({
    eventName = ["INSERT", "MODIFY"]
    dynamodb  = { Keys = { SK = { S = ["META"] } } }
  })

  # Catalogos de seed, un archivo JSON por tipo cargado como items
  # { "CATEGORIA#0001" = {...}, "ZONA#0001" = {...}, ... }
  seed_items = merge([
    for tipo in ["categoria", "zona", "urgencia"] : {
      for item in jsondecode(file("${path.module}/seed/${tipo}.json")) :
      "${upper(tipo)}#${format("%04d", item.id)}" => merge(item, { tipo = tipo })
    }
  ]...)

  # Momento base del seed: la medianoche (UTC) del primer apply, congelada en el
  # state (ver seed_solicitudes.tf). Que sea medianoche hace que el dia de cada
  # evento se pueda calcular sin conocer la hora del apply
  seed_now = "${formatdate("YYYY-MM-DD", terraform_data.seed_ancla.output)}T00:00:00Z"

  # Solicitudes de demo. Un objeto por solicitud con su historial de seguimiento;
  # las fechas son relativas a la creacion (en horas) y cliente/profesional/actor
  # referencian la clave de demo_users (el sub de Cognito se resuelve recien en
  # database.tf). solicitudes.json son las recientes, armadas a mano;
  # solicitudes_historicas.json las de las semanas anteriores, generadas con
  # back/scripts/generar_seed_historico.py para que analytics tenga que mostrar
  solicitudes_seed = concat(
    jsondecode(file("${path.module}/seed/solicitudes.json")),
    jsondecode(file("${path.module}/seed/solicitudes_historicas.json")),
  )

  # Transiciones del flujo, las mismas que traduce barriofix/eventos.py
  transiciones = {
    "PENDIENTE>ASIGNADO"    = "aceptar"
    "ASIGNADO>EN_PROGRESO"  = "iniciar"
    "EN_PROGRESO>RESUELTO"  = "resolver"
    "ASIGNADO>PENDIENTE"    = "liberar"
    "EN_PROGRESO>PENDIENTE" = "liberar"
  }

  # Eventos de analytics del seed: el mismo historial que se carga en DynamoDB,
  # traducido como lo haria la Lambda analytics. Van en horas relativas y con
  # usernames; la fecha y el sub de Cognito se resuelven en analytics.tf
  eventos_seed = merge(
    # Un evento por paso del seguimiento; el primero es la creacion
    merge([
      for s in local.solicitudes_seed : {
        for idx, seg in s.seguimiento :
        "${s.id}#${format("%02d", idx + 1)}" => {
          id_solicitud = s.id
          tipo = (idx == 0 ? "creada" : seg.estado == "CANCELADO" ? "cancelar"
          : lookup(local.transiciones, "${s.seguimiento[max(idx - 1, 0)].estado}>${seg.estado}", "cambio_estado"))
          estado_anterior = idx == 0 ? null : s.seguimiento[max(idx - 1, 0)].estado
          estado_nuevo    = seg.estado
          cliente         = s.cliente
          # Al liberar o cancelar el paso no trae profesional: es el que estaba
          profesional  = seg.profesional != null ? seg.profesional : s.seguimiento[max(idx - 1, 0)].profesional
          id_categoria = s.id_categoria
          id_zona      = s.id_zona
          id_urgencia  = s.id_urgencia
          edad_horas   = s.creada_hace_horas
          offset_horas = seg.offset_horas
          puntuacion   = null
        }
      }
    ]...),
    # Y uno por cada calificacion
    {
      for s in local.solicitudes_seed : "${s.id}#cal" => {
        id_solicitud    = s.id
        tipo            = "calificada"
        estado_anterior = "RESUELTO"
        estado_nuevo    = "RESUELTO"
        cliente         = s.cliente
        profesional     = s.profesional
        id_categoria    = s.id_categoria
        id_zona         = s.id_zona
        id_urgencia     = s.id_urgencia
        edad_horas      = s.creada_hace_horas
        offset_horas    = s.calificacion.offset_horas
        puntuacion      = s.calificacion.puntuacion
      } if s.calificacion != null
    },
  )

  # Dia de cada evento relativo a seed_now (0 = hoy, -1 = ayer...) -> claves de
  # eventos. Un objeto en S3 por dia, como los que escribe la Lambda
  eventos_seed_por_dia = {
    for k, e in local.eventos_seed : tostring(floor((e.offset_horas - e.edad_horas) / 24)) => k...
  }

  # id de solicitud -> objeto, con la fecha de creacion ya calculada
  solicitudes_by_id = {
    for s in local.solicitudes_seed :
    s.id => merge(s, {
      fecha_creacion = timeadd(local.seed_now, "-${s.creada_hace_horas}h")
    })
  }

  # Pasos de seguimiento aplanados. Clave "<id>#<nnnn>" para el for_each; el SK
  # se arma con el indice del paso para que ordene cronologico dentro de la SOL.
  seguimientos_seed = merge([
    for s in local.solicitudes_seed : {
      for idx, seg in s.seguimiento :
      "${s.id}#${format("%04d", idx + 1)}" => {
        id_solicitud = s.id
        sk           = "SEG#${format("%04d", idx + 1)}"
        estado       = seg.estado
        actor        = seg.actor
        profesional  = seg.profesional
        motivo       = seg.motivo
        fecha_desde  = timeadd(timeadd(local.seed_now, "-${s.creada_hace_horas}h"), "${seg.offset_horas}h")
      }
    }
  ]...)

  front_origin = var.front_origin != "" ? var.front_origin : "http://${local.bucket_front}.s3-website-${var.region}.amazonaws.com"

  # Content-Type por extension para los archivos del front subidos a S3
  content_types = {
    html = "text/html"
    css  = "text/css"
    js   = "application/javascript"
    json = "application/json"
    svg  = "image/svg+xml"
    png  = "image/png"
    jpg  = "image/jpeg"
    ico  = "image/x-icon"
    map  = "application/json"
    txt  = "text/plain"
  }

  # Prefijo del dominio de la Hosted UI, unico globalmente
  cognito_domain_prefix = "${var.project}-${local.suffix}"

  # Lambdas de API que ya existen, cada una con sus rutas. Agregar un dominio es
  # sumar una entrada aca y su carpeta en back/functions/
  api_functions = {
    catalogos = {
      routes = ["GET /api/categorias", "GET /api/zonas", "GET /api/urgencias"]
      public = true
    }
    usuarios = {
      routes = ["GET /api/auth/me", "POST /api/auth/registro"]
      public = false
    }
    solicitudes = {
      routes = [
        "GET /api/solicitudes",
        "POST /api/solicitudes",
        "GET /api/trabajos",
        "GET /api/solicitudes/{id}",
        "GET /api/solicitudes/{id}/seguimiento",
      ]
      public = false
    }
    fotos = {
      routes = [
        "POST /api/solicitudes/{id}/fotos",
        "GET /api/solicitudes/{id}/fotos",
      ]
      public = false
    }
    flujo = {
      routes = [
        "POST /api/solicitudes/{id}/aceptar",
        "POST /api/solicitudes/{id}/iniciar",
        "POST /api/solicitudes/{id}/resolver",
        "POST /api/solicitudes/{id}/liberar",
        "POST /api/solicitudes/{id}/cancelar",
      ]
      public = false
    }
    calificaciones = {
      routes = [
        "POST /api/solicitudes/{id}/calificacion",
        "GET /api/solicitudes/{id}/calificacion",
      ]
      public = false
    }
  }

  # Aplana api_functions en un mapa ruta -> {fn, public} para el for_each de las rutas
  api_routes = merge([
    for fn, cfg in local.api_functions : {
      for ruta in cfg.routes : ruta => { fn = fn, public = cfg.public }
    }
  ]...)

  # Mock data, usuarios de demo. username (clave) -> datos del perfil.
  # Las categorias de los profesionales referencian los ids de seed/categoria.json
  # y las zonas los de seed/zona.json. Ningun profesional cubre el sur (Villa
  # Lugano, Mataderos, Villa Soldati): es el desierto de oferta que muestra analytics.
  # descripcion queda "" en los clientes: solo la usan los profesionales (ver database.tf).
  demo_users = {
    # Clientes
    "juan.perez" = {
      email       = "juan.perez@example.com"
      nombre      = "Juan"
      apellido    = "Pérez"
      telefono    = "+54 11 5555-1001"
      rol         = "CLIENTE"
      categorias  = []
      zonas       = []
      descripcion = ""
    }
    "sofia.garcia" = {
      email       = "sofia.garcia@example.com"
      nombre      = "Sofía"
      apellido    = "García"
      telefono    = "+54 11 5555-1002"
      rol         = "CLIENTE"
      categorias  = []
      zonas       = []
      descripcion = ""
    }
    "martin.lopez" = {
      email       = "martin.lopez@example.com"
      nombre      = "Martín"
      apellido    = "López"
      telefono    = "+54 11 5555-1003"
      rol         = "CLIENTE"
      categorias  = []
      zonas       = []
      descripcion = ""
    }
    "valentina.romero" = {
      email       = "valentina.romero@example.com"
      nombre      = "Valentina"
      apellido    = "Romero"
      telefono    = "+54 11 5555-1004"
      rol         = "CLIENTE"
      categorias  = []
      zonas       = []
      descripcion = ""
    }
    "lucas.fernandez" = {
      email       = "lucas.fernandez@example.com"
      nombre      = "Lucas"
      apellido    = "Fernández"
      telefono    = "+54 11 5555-1005"
      rol         = "CLIENTE"
      categorias  = []
      zonas       = []
      descripcion = ""
    }

    # Profesionales
    "carlos.electricista" = {
      email       = "carlos.gomez@example.com"
      nombre      = "Carlos"
      apellido    = "Gómez"
      telefono    = "+54 11 5555-2001"
      rol         = "PROFESIONAL"
      categorias  = [2, 17, 30]
      zonas       = [21, 36, 2, 8, 28]
      descripcion = "Electricista matriculado. Instalaciones eléctricas, reparación de cortocircuitos, tableros, térmicas, disyuntores y luminarias."
    }
    "diego.plomero" = {
      email       = "diego.martinez@example.com"
      nombre      = "Diego"
      apellido    = "Martínez"
      telefono    = "+54 11 5555-2002"
      rol         = "PROFESIONAL"
      categorias  = [1, 25]
      zonas       = [21, 5, 20, 11, 36]
      descripcion = "Plomero con experiencia en pérdidas de agua, grifería, cañerías, destapaciones y reparación de sanitarios."
    }
    "mariano.gasista" = {
      email       = "mariano.rodriguez@example.com"
      nombre      = "Mariano"
      apellido    = "Rodríguez"
      telefono    = "+54 11 5555-2003"
      rol         = "PROFESIONAL"
      categorias  = [3, 4]
      zonas       = [8, 2, 7, 13, 21]
      descripcion = "Gasista especializado en instalación, mantenimiento y reparación de calefones, termotanques y cocinas."
    }
    "pablo.pintor" = {
      email       = "pablo.sanchez@example.com"
      nombre      = "Pablo"
      apellido    = "Sánchez"
      telefono    = "+54 11 5555-2004"
      rol         = "PROFESIONAL"
      categorias  = [7, 8, 10, 25]
      zonas       = [5, 20, 28, 30, 10]
      descripcion = "Pintor de interiores y exteriores. Preparación de paredes, pintura, enduido, impermeabilización y terminaciones."
    }
    "federico.tecnico" = {
      email       = "federico.torres@example.com"
      nombre      = "Federico"
      apellido    = "Torres"
      telefono    = "+54 11 5555-2005"
      rol         = "PROFESIONAL"
      categorias  = [4, 14, 15, 16]
      zonas       = [36, 21, 8, 5, 28]
      descripcion = "Técnico especializado en aire acondicionado, refrigeración y mantenimiento general de equipos domiciliarios."
    }
  }

  # "<usuario>#<categoria>" -> {usuario, categoria}, un item de membresia por par
  demo_membresias = merge([
    for u, d in local.demo_users : {
      for c in d.categorias : "${u}#${c}" => { usuario = u, categoria = c }
    } if d.rol == "PROFESIONAL"
  ]...)
}
