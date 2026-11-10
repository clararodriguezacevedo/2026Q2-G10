variable "region" {
  description = "Region de AWS donde se despliega toda la infra"
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefijo de nombres y tag comun de todos los recursos"
  type        = string
  default     = "barriofix"

  # Va en nombres de bucket, asi que tiene que cumplir las reglas de S3
  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project))
    error_message = "project solo puede tener minusculas, numeros y guiones."
  }
}

variable "vpc_cidr" {
  description = "Bloque CIDR de la VPC"
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr tiene que ser un bloque CIDR IPv4 valido."
  }
}

variable "azs" {
  description = "Letras de las Availability Zones a usar (se anteponen a la region)"
  type        = list(string)
  default     = ["a", "b"]

  # Dos AZs como minimo, las subredes privadas van una por AZ
  validation {
    condition     = length(var.azs) >= 2
    error_message = "Hacen falta al menos 2 Availability Zones."
  }
}

variable "lab_role_name" {
  description = "Rol de instancia o servicio preexistente del Learner Lab"
  type        = string
  default     = "LabRole"
}

variable "powertools_layer_arn" {
  description = "ARN del layer publico de AWS Lambda Powertools (Python 3.12, x86_64)"
  type        = string
  default     = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-x86_64:39"
}

variable "restrict_dynamodb_to_vpc" {
  description = "Si es true, agrega una resource policy que solo permite acceso a DynamoDB desde el endpoint de la VPC. Apagarlo para poder mirar la tabla desde la consola"
  type        = bool
  default     = false
}

variable "demo_password" {
  description = "Contraseña de los usuarios de demo (mock data). Es ficticia"
  type        = string
  default     = "BarrioFix-Demo-2026!"
  sensitive   = true
}

variable "front_origin" {
  description = "Origen del frontend permitido en CORS. Si queda vacio, se usa la URL del bucket website"
  type        = string
  default     = ""
}

variable "lambda_memory" {
  description = "Memoria (MB) de las Lambdas de API"
  type        = number
  default     = 1024

  validation {
    condition     = var.lambda_memory >= 128 && var.lambda_memory <= 10240
    error_message = "lambda_memory tiene que estar entre 128 y 10240 MB."
  }
}

variable "lambda_timeout" {
  description = "Timeout (s) de las Lambdas de API"
  type        = number
  default     = 15

  validation {
    condition     = var.lambda_timeout >= 1 && var.lambda_timeout <= 900
    error_message = "lambda_timeout tiene que estar entre 1 y 900 segundos."
  }
}

variable "api_throttle_rate" {
  description = "Requests por segundo sostenidas por stage en API Gateway"
  type        = number
  default     = 50
}

variable "api_throttle_burst" {
  description = "Rafaga maxima de requests en API Gateway"
  type        = number
  default     = 100
}

variable "front_dist_path" {
  description = "Ruta al dist/ ya compilado del front. Vacio = no subir archivos (solo config.json)."
  type        = string
  default     = ""
}

variable "auth_callback_reserved_concurrency" {
  description = "Concurrencia reservada de auth-callback (tope ante floods al endpoint publico)"
  type        = number
  default     = 10
}

variable "use_eventbridge_pipe" {
  description = "Puente Stream -> SNS con EventBridge Pipes. En false usa la Lambda publicador, por si el LabRole no confia en pipes.amazonaws.com"
  type        = bool
  default     = true
}

variable "email_max_concurrency" {
  description = "Invocaciones de enviar-email en paralelo (tope contra el rate limit del proveedor SMTP)"
  type        = number
  default     = 2

  validation {
    condition     = var.email_max_concurrency >= 2 && var.email_max_concurrency <= 1000
    error_message = "email_max_concurrency tiene que estar entre 2 y 1000 (limites de SQS para Lambda)."
  }
}

variable "alarm_email" {
  description = "Email que recibe las alarmas (hay que confirmar la suscripcion). Vacio = sin suscripcion"
  type        = string
  default     = ""
}

variable "google_maps_api_key" {
  # Key publica: el navegador la recibe igual en config.json, no es un secreto
  description = "API key de Google Maps para el mapa de ubicacion del front. Vacia = el front muestra solo la direccion"
  type        = string
  default     = "AIzaSyC3MJ0gk1o-X1_JC8BtwuXEPOMLbO85-OM"
}
