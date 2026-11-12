# Terraform

Toda la infraestructura está en terraform/organization, con un archivo por capa (network,
compute, api, auth, database, storage, frontend, secrets, eventos, notificaciones, analytics,
observabilidad y seguridad), más variables, outputs, locals y data sources. El state se explica en el
[README](../README.md#state).

## Módulos

Creamos el módulo [lambda_function](../terraform/modules/lambda_function) y todas las Lambdas
pasan por él. Arma el zip de cada función con su propio hash, así un cambio en un dominio no
redeploya las demás. Crea el log group desde Terraform para que el destroy no deje grupos
sueltos, y si se le pasan, agrega la VPC, los layers, las variables de entorno y la concurrencia
reservada. Las seis Lambdas de la API salen de una sola instancia del módulo con for_each, y las
demás (pre-signup, auth-callback, foto-subida, analytics, notif-cliente, matcher,
publicar-notificacion y suscribir-usuario) lo usan una vez cada una.

También usamos el módulo externo [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws),
que crea la VPC, las subredes privadas y las route tables. Encima de eso, en network.tf,
agregamos los Gateway Endpoints de S3 y DynamoDB y el security group de las Lambdas.

## Variables y outputs

Todo lo que puede cambiar entre cuentas o entornos es una variable con un default que funciona.
Entre otras, la región, el prefijo de nombres, el CIDR de la VPC y las AZs, la memoria y el
timeout de las Lambdas, el throttling de la API, la contraseña de los usuarios de demo (marcada
como sensitive), la key de Google Maps, cuántas notificaciones se publican en paralelo (notif_max_concurrency), un
mail opcional para las alarmas (alarm_email) y qué servicios de seguridad se activan
(servicios_seguridad). Las que pueden romper algo tienen validation, por
ejemplo el prefijo tiene que servir como nombre de bucket, el CIDR tiene que ser válido y Security
Hub no se puede prender sin Config.

Los outputs más útiles son frontend_url, api_url y hosted_ui_login_url, que el workflow de
deploy muestra al final. También salen los nombres de la tabla y los buckets, los datos de
Cognito, el topic de eventos, el workgroup de Athena y los ids de la red.

## Funciones

Las que más usamos:

- format arma los nombres de los buckets con el account id y las claves del seed, como CATEGORIA#0001.
- file y jsondecode leen los JSON de seed/, y jsonencode escribe las policies, los ítems de DynamoDB y el config.json del front.
- merge aplana listas de mapas en un solo mapa para recorrerlas con for_each, como las rutas de la API o el seed.
- concat junta los dos JSON de solicitudes de demo, y lookup sobre un mapa de transiciones traduce cada paso del seguimiento al evento que generaría la Lambda.
- timeadd calcula las fechas del seed relativas al primer apply, floor agrupa los eventos por día y formatdate arma la partición de cada uno.
- cidrsubnet saca una subred por AZ a partir del CIDR de la VPC.
- fileset y filemd5 recorren el build del front y suben solo los archivos que cambiaron.
- lookup, junto con split, reverse y lower, elige el Content-Type según la extensión de cada archivo.
- fileset, trimsuffix y templatefile cargan cada consulta de sql/ en Athena con el nombre de la base ya resuelto.

Además hay usos más chicos de try, upper, tostring, toset, max, trimprefix y, en las
validaciones, de can, regex, cidrhost y length.

## Meta-argumentos

Usamos los cuatro.

for_each es el que más aparece. Crea las Lambdas de la API con sus rutas e integraciones, los
usuarios de demo y sus ítems de membresía, los ítems del seed, los eventos de demo en S3, los
archivos del front, una alarma por cada DLQ y por cada cola, las tablas de dimensiones y las
consultas guardadas de Athena.

count crea la resource policy de DynamoDB solo si restrict_dynamodb_to_vpc está en true,
suscribe el mail de alarmas solo si se pasa uno y prende cada servicio de seguridad (GuardDuty,
Inspector, Config y Security Hub) según servicios_seguridad.

depends_on cubre los casos donde no hay una referencia que ordene las cosas. El log group existe
antes que la función, S3 y SNS tienen permiso para invocar a cada Lambda antes de registrarla, la
cola de analytics acepta mensajes del topic antes de suscribirla, y el Pipe arranca después de
cargar el seed (si no, los ítems de demo entrarían dos veces a analytics).

lifecycle aparece de dos formas. create_before_destroy en el layer común, para que las Lambdas no
se queden sin layer cuando se reemplaza. Y ignore_changes en los ítems del seed (para no pisar lo
que se cambió desde la app), en el terraform_data que guarda el momento del primer apply (para que
las fechas del seed no se muevan) y en el secreto SMTP (para no pisar la credencial que carga el
pipeline).

Las columnas de las tablas de Athena salen de un bloque dynamic sobre listas en locals.

## Locals y data sources

En locals.tf está lo que se calcula una vez y se usa en varios archivos, como los tags, los
nombres de los buckets, el seed ya transformado en ítems y en eventos, los usuarios de demo y el
mapa de Lambdas de la API con sus rutas. Para agregar un dominio nuevo alcanza con sumar una
entrada a ese mapa y su carpeta en back/functions.

Los data sources resuelven lo que no crea Terraform. El account id, para que los nombres de los
buckets sean únicos, y el LabRole, que es el rol que usan todas las Lambdas porque en el lab no se
pueden crear roles. archive_file arma los zips.
