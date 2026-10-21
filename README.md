# BarrioFix

Grupo 10, Cloud Computing (82.08), ITBA. 5 integrantes.

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
compute.tf, api.tf, auth.tf, database.tf, storage.tf, frontend.tf, secrets.tf), y aparte están
variables, outputs, locals y data sources. En seed/ quedan los JSON con la mock data:
categorías, zonas, urgencias y las solicitudes de demo.

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
timeout. Para destruir hay que vaciar primero los buckets de frontend y media, porque el provider
que usamos para S3 no los vacía solo. Media tiene versionado, así que además de los archivos hay
que borrar las versiones viejas; .github/scripts/vaciar-bucket.sh hace las dos cosas. Después se
corre terraform destroy -parallelism=1.

## Terraform

### Módulos

Creamos el módulo [lambda_function](terraform/modules/lambda_function). Cada Lambda del
proyecto pasa por él: arma el zip de la función con su propio hash, así un cambio en un dominio
no redeploya las demás, crea el log group desde Terraform para que el destroy no deje grupos
sueltos y, si se le pasan, agrega la VPC, los layers, las variables de entorno y la concurrencia
reservada. Las seis Lambdas de la API salen de una sola instancia del módulo con for_each, y las
tres funciones restantes (pre-signup, auth-callback y foto-subida) lo usan una vez cada una.

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

Además hay usos más chicos de try, upper, tostring, toset y, en las validaciones, de can,
regex, cidrhost y length.

### Meta-argumentos

Usamos los cuatro. for_each es el que más aparece: crea las Lambdas de la API, sus rutas e
integraciones en API Gateway, los usuarios de demo, los ítems del seed y los archivos del front.
count crea la resource policy de DynamoDB solo si restrict_dynamodb_to_vpc está en true.
depends_on asegura que el log group exista antes que la función y que S3 tenga permiso para
invocar a foto-subida antes de registrar la notificación. Y lifecycle aparece de dos formas:
create_before_destroy en el layer común, para que las Lambdas no se queden sin layer cuando se
reemplaza, e ignore_changes en los ítems del seed, para que un apply no pise lo que se cambió
desde la app.

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
