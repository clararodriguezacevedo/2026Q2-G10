# BarrioFix

Grupo 10, Cloud Computing (82.08), ITBA.

BarrioFix es una plataforma para pedir reparaciones en el barrio: un cliente publica una
solicitud y un profesional de esa categoría la toma, la resuelve y después recibe una
calificación. Para esta entrega migramos la app a una arquitectura serverless en AWS y la
desplegamos entera con Terraform.

El frontend es una app de React que se sirve como sitio estático desde S3 y vive en otro
repo, [barriofix-front](https://github.com/clararodriguezacevedo/barriofix-front). Este repo
tiene el backend (Lambdas en Python 3.12 detrás de API Gateway), la infraestructura en
Terraform y los workflows de GitHub Actions. Los datos están en DynamoDB y el login lo maneja
Cognito con su Hosted UI. Cómo se conectan las piezas está explicado en
[docs/arquitectura.md](docs/arquitectura.md).

## Organización del repo

```
back/functions/       un handler por dominio, más las dos funciones por evento
back/layers/common/   código compartido entre las Lambdas (layer)
back/scripts/         build.sh, que arma el layer
terraform/bootstrap/  crea el bucket del state
terraform/modules/    nuestro módulo lambda_function
terraform/organization/  la arquitectura completa, un archivo por capa
docs/                 arquitectura y capturas
.github/workflows/    deploy, destroy y los checks del PR
```

Dentro de terraform/organization cada archivo agrupa una parte de la infra (network.tf,
compute.tf, api.tf, auth.tf, database.tf, storage.tf, frontend.tf, secrets.tf, eventos.tf,
analytics.tf, observabilidad.tf), y aparte están variables, outputs, locals y data sources. En
seed/ quedan los JSON con la mock data: categorías, zonas, urgencias, las solicitudes de demo
recientes (solicitudes.json, armadas a mano) y un histórico de las semanas anteriores
(solicitudes_historicas.json, que genera back/scripts/generar_seed_historico.py). En sql/ están
las consultas de negocio que se guardan en Athena.

## Cómo desplegar

Hace falta una cuenta de AWS (usamos el Learner Lab). Todo el despliegue corre en GitHub
Actions:

1. Cargar como secrets del repo AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY y AWS_SESSION_TOKEN,
   que salen de AWS Details en el lab. Para el mapa de las solicitudes no hace falta cargar
   nada: la key de Google Maps ya viene como default de la variable google_maps_api_key y es
   AIzaSyC3MJ0gk1o-X1_JC8BtwuXEPOMLbO85-OM. Es una key pública a propósito, porque el
   navegador la recibe igual en el config.json y en cada pedido a Google Maps, así que no hay
   problema en que esté en el repo. Si se quiere usar otra, se carga como secret
   GOOGLE_MAPS_API_KEY y el deploy la usa en lugar de la nuestra.

   ![Secrets del repo](docs/img/secrets.png)

2. Abrir un pull request. Ahí corren los checks que no necesitan credenciales: formato,
   terraform validate, tfsec y el build del front.

   ![Checks del PR](docs/img/pr-checks.png)

3. Mergear a main, o correr el workflow Deploy a mano. El workflow compila el front, arma el
   layer, crea el bucket del state si todavía no existe y después hace init, validate, plan y
   apply. El apply usa el plan guardado, así se aplica exactamente lo que se planeó. La primera 
   vez tarda entre 15 y 30 minutos.

4. Cuando termina, el resumen del run tiene la URL del sitio, la de la API y la del login.

   ![Resumen del deploy](docs/img/deploy-summary.webp)

Para eliminar todo está el workflow Destroy, que pide escribir "destroy" para confirmar.

Terraform crea diez usuarios de demo, todos con la contraseña BarrioFix-Demo-2026!. Los
clientes son juan.perez, sofia.garcia, martin.lopez, valentina.romero y lucas.fernandez, y los
profesionales son carlos.electricista, diego.plomero, mariano.gasista, pablo.pintor y
federico.tecnico.

### Sin GitHub Actions

Se puede hacer lo mismo desde una terminal con las credenciales del lab cargadas. Hace falta
Terraform 1.10 o más nuevo, Python 3.12 y Node 20, y el repo del front clonado al lado de este:

```bash
cd ../barriofix-front && npm ci && npm run build && cd -
bash back/scripts/build.sh

cd terraform/bootstrap
terraform init
terraform apply

cd ../organization
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
terraform init -backend-config="bucket=barriofix-tfstate-${ACCOUNT_ID}"
terraform validate
terraform plan -out=tfplan -var "front_dist_path=$(pwd)/../../../barriofix-front/dist"
terraform apply -parallelism=1 tfplan
terraform output
```

El bootstrap se corre una sola vez por cuenta. Se usa parallelism=1 por el lab, si se crean
varias Lambdas dentro de la VPC al mismo tiempo, la creación de las interfaces de red suele dar
timeout. Para destruir hay que vaciar primero los buckets de frontend, media y analytics, porque el provider
que usamos para S3 no los vacía solo. Media tiene versionado, así que además de los archivos hay
que borrar las versiones viejas; .github/scripts/vaciar-bucket.sh hace las dos cosas. Después se
corre terraform destroy -parallelism=1.

## Eventos y analytics

Cada cambio de una solicitud (se crea, se acepta, se inicia, se resuelve, se libera, se cancela
o se califica) se convierte en un evento sin que ninguna Lambda lo publique a mano. La tabla
tiene DynamoDB Streams y un EventBridge Pipe lleva cada cambio de la META a un topic SNS. De ahí
sale el fan-out a los consumidores. Hoy hay uno, analytics: una cola SQS que la Lambda analytics
consume en lotes de hasta 100 mensajes, escribiendo los eventos como JSON en un bucket de S3
particionado por fecha. Athena consulta ese bucket con una tabla de Glue que calcula las
particiones sola (partition projection), así que no hace falta un crawler.

Para ver los resultados, en la consola de Athena se elige el workgroup barriofix-analytics y en
Saved queries están las consultas de negocio: fill rate a 48 horas por zona, combinaciones de
categoría y zona donde los trabajos no se toman, el funnel completo, profesionales que aceptan y
sueltan trabajos, cancelaciones según el estado desde el que se cancela e integridad de la
urgencia. Las consultas cruzan los eventos con tablas de categorías, zonas, urgencias y usuarios
de demo, así muestran nombres y no ids.

Athena tiene datos desde el primer deploy. Las 80 solicitudes de demo (20 recientes y 60 del
histórico) se cargan en DynamoDB y, del mismo seed, Terraform arma sus eventos en S3: lo que se
ve en la app y lo que devuelven las consultas sale de los mismos datos. El histórico está armado
para que cada consulta muestre algo (zonas del sur desatendidas, un solo gasista, un profesional
que suelta trabajos, urgencia inflada). Las fechas se calculan desde el momento del primer apply,
que queda guardado en el state, así no se mueven en los apply siguientes.

El otro consumidor son las notificaciones por mail. Ante cada cambio de estado, la Lambda
notif-cliente decide a quién avisar (al cliente cuando aceptan, empiezan, resuelven o liberan su
solicitud, y al profesional asignado cuando el cliente cancela), busca su email en el perfil y
devuelve el mail armado. Esa Lambda está dentro de la VPC y SQS no tiene Gateway Endpoint, así
que no encola: el destino on-success de la invocación lleva el resultado a la cola email. De ahí
lo toma enviar-email, la única función que habla SMTP, que va fuera de la VPC y no toca datos. El
event source mapping limita cuántos envíos corren en paralelo para no pasarse del rate limit del
proveedor; lo que no llega a mandarse espera en la cola.

El tercer consumidor es el matcher. Cuando una solicitud queda disponible (se crea o un
profesional la libera), avisa por mail a los profesionales que podrían tomarla: los disponibles que
ofrecen esa categoría y cubren esa zona. Al profesional que la acaba de liberar no le avisa. La
suscripción al topic filtra por estado, así que el resto de los cambios ni siquiera invoca la
Lambda. Como notif-cliente, está en la VPC y devuelve los mails (uno por profesional) para que el
destino on-success los lleve a la cola email.

Para encontrar a esos profesionales sin recorrer la tabla hay un cuarto GSI,
profesionales_por_categoria. El perfil guarda las categorías como un conjunto, y DynamoDB no puede
indexar un valor que está adentro de un conjunto, así que el registro escribe además un ítem chico
por cada categoría del profesional (USER#sub / PROCAT#categoría) con la categoría como clave del
índice, sus zonas y su email. El perfil y esos ítems se escriben en una sola transacción. El
matcher hace una Query por categoría y filtra por zona y disponibilidad sobre ese conjunto chico,
igual que /api/trabajos hace con los pendientes.

Las zonas del profesional salen del mismo catálogo que las de las solicitudes, así el matching es
por id. En el registro del front, los barrios de CABA se eligen tocando su polígono en el mapa y
los partidos del AMBA con chips; sin key de Google Maps quedan todas como chips. Los polígonos son
el GeoJSON de barrios del portal de datos abiertos de la Ciudad, simplificado. Descartamos dejar
que el profesional dibuje un área libre: habría que matchear por coordenadas (geohash), que
DynamoDB no resuelve solo. Ningún profesional de demo cubre Villa Lugano, Mataderos ni Villa
Soldati, así que ahí el matcher no avisa a nadie, que es el mismo desierto de oferta que muestran
las consultas de Athena.

Para que los mails salgan de verdad hay que cargar como secrets del repo SMTP_HOST, SMTP_USER,
SMTP_PASSWORD y SMTP_FROM (y SMTP_PORT si no es 587), por ejemplo con un inbox de prueba de
Mailtrap. El deploy los copia a Secrets Manager después del apply, así la credencial nunca pasa
por el código ni por el state. Sin esos secrets todo funciona igual, pero enviar-email simula los
envíos y deja en el log qué mail habría mandado.

Si el lab no deja que EventBridge Pipes use el LabRole (se ve con
`aws iam get-role --role-name LabRole --query Role.AssumeRolePolicyDocument`, tiene que figurar
pipes.amazonaws.com), se despliega con `-var use_eventbridge_pipe=false` y el puente pasa a ser la
Lambda publicador, que hace lo mismo. Las DLQ de las colas tienen alarmas de CloudWatch que
publican en el topic barriofix-alarmas; con `-var alarm_email=...` además llegan por mail.

## Terraform

### Módulos

Creamos el módulo [lambda_function](terraform/modules/lambda_function). Cada Lambda del
proyecto pasa por él: arma el zip de la función con su propio hash, así un cambio en un dominio
no redeploya las demás, crea el log group desde Terraform para que el destroy no deje grupos
sueltos y, si se le pasan, agrega la VPC, los layers, las variables de entorno y la concurrencia
reservada. Las seis Lambdas de la API salen de una sola instancia del módulo con for_each, y las
funciones restantes (pre-signup, auth-callback, foto-subida, analytics, notif-cliente, matcher,
enviar-email y, solo sin el Pipe, publicador) lo usan una vez cada una.

También usamos el módulo externo [terraform-aws-modules/vpc](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws),
que crea la VPC, las subredes privadas y las route tables. Encima de eso, en network.tf,
agregamos los Gateway Endpoints de S3 y DynamoDB y el security group de las Lambdas.

### Variables y outputs

Todo lo que puede cambiar entre cuentas o entornos es una variable con un default que funciona:
región, prefijo de nombres, CIDR de la VPC y AZs, memoria y timeout de las Lambdas, throttling
de la API, la concurrencia reservada del callback de login, la contraseña de los usuarios de
demo (marcada como sensitive) y la key de Google Maps, entre otras. Las que pueden romper algo
tienen validation; por ejemplo, el prefijo tiene que servir como nombre de bucket y el CIDR
tiene que ser válido.

Los outputs más útiles son frontend_url, api_url y hosted_ui_login_url, que el workflow de
deploy muestra al final. También salen los nombres de la tabla y los buckets, los datos de
Cognito y los ids de la red.

### Funciones

Las que más usamos:

- format arma los nombres de los buckets con el account id y las claves del seed, como CATEGORIA#0001.
- file y jsondecode leen los JSON de seed/, y jsonencode escribe las policies, los ítems de DynamoDB y el config.json del front.
- merge aplana listas de mapas en un solo mapa para poder recorrerlas con for_each, como las rutas de la API o el seed.
- timestamp y timeadd calculan las fechas de las solicitudes de demo relativas al momento del apply.
- cidrsubnet saca una subred por AZ a partir del CIDR de la VPC.
- fileset y filemd5 recorren el build del front y suben solo los archivos que cambiaron.
- lookup, junto con split, reverse y lower, elige el Content-Type según la extensión de cada archivo.
- fileset, trimsuffix y templatefile cargan cada consulta de sql/ en Athena con el nombre de la base ya resuelto, y split con trimprefix sacan su descripción de la primera línea.
- concat junta los dos JSON de solicitudes, y lookup sobre un mapa de transiciones traduce cada paso del seguimiento al evento que generaría la Lambda. floor agrupa esos eventos por día y formatdate arma la partición de cada uno.

Además hay usos más chicos de try, upper, tostring, toset y, en las validaciones, de can,
regex, cidrhost y length.

### Meta-argumentos

Usamos los cuatro. for_each es el que más aparece: crea las Lambdas de la API, sus rutas e
integraciones en API Gateway, los usuarios de demo y sus ítems de membresía, los ítems del seed,
los archivos del front,
una alarma por cada DLQ y por cada cola con consumidor, las tablas de dimensiones y las consultas
guardadas de Athena. count crea la resource policy de
DynamoDB solo si restrict_dynamodb_to_vpc está en true, elige entre el Pipe y la Lambda
publicador según use_eventbridge_pipe y suscribe el mail de alarmas solo si se pasa uno.
depends_on asegura que el log group exista antes que la función, que S3 tenga permiso para
invocar a foto-subida antes de registrar la notificación, que SNS tenga permiso para invocar a
notif-cliente y al matcher antes de suscribirlos, que la cola de analytics acepte mensajes del
topic antes de suscribirla y que el Pipe arranque después de cargar el seed (si
no, los ítems de demo entrarían dos veces a analytics). Las columnas de las tablas de Athena
salen de un bloque dynamic sobre listas en locals. Y lifecycle aparece de dos formas:
create_before_destroy en el layer común, para que las Lambdas no se queden sin layer cuando se
reemplaza, e ignore_changes en los ítems del seed, para que un apply no pise lo que se cambió
desde la app, en el terraform_data que guarda el momento del primer apply y en el secreto SMTP,
para que Terraform no pise la credencial que carga el pipeline.

### Locals y data sources

En locals.tf está lo que se calcula una vez y se usa en varios archivos: los tags, los nombres
de los buckets, el seed ya transformado, los usuarios de demo y el mapa de Lambdas de la API con
sus rutas. Para agregar un dominio nuevo alcanza con sumar una entrada a ese mapa y su carpeta en
back/functions.

Los data sources resuelven lo que no crea Terraform: el account id, que usamos para que los
nombres de los buckets sean únicos, y el LabRole, que es el rol que usan todas las Lambdas
porque en el lab no se pueden crear roles. archive_file arma los zips.

### State

El state está en un bucket de S3 que lleva el account id en el nombre y usa use_lockfile para
el lock, sin tabla de DynamoDB aparte. Ese bucket no lo puede crear el mismo Terraform que lo
usa como backend, así que lo crea un bootstrap aparte con state local. El nombre del bucket se
pasa en el init con -backend-config y el account id sale de un data source, así que nada de la
cuenta queda escrito en el código y el mismo pipeline despliega en cualquier cuenta.
