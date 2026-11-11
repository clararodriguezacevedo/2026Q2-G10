# Arquitectura de BarrioFix

Todo corre sobre servicios administrados de AWS. Estos son los que usamos y para qué.

- AWS Lambda: el backend. Una función por dominio de la API, más las que se disparan por eventos, con un layer de código común y el layer público de Powertools.
- Amazon API Gateway (HTTP API): la entrada HTTPS a las Lambdas. Valida el token de Cognito y aplica throttling.
- Amazon DynamoDB: los datos de la app, en una sola tabla con cuatro índices secundarios. Su Stream es la fuente de los eventos.
- Amazon EventBridge Pipes: lleva cada cambio del Stream a SNS, sin una Lambda en el medio.
- Amazon SNS: el topic de eventos, que reparte cada cambio entre los consumidores.
- Amazon SQS: las colas de analytics y de mails, y las colas de descarte (DLQ).
- Amazon Athena y AWS Glue: consultas SQL sobre los eventos guardados en S3.
- Amazon Cognito: registro y login con la Hosted UI, y emisión de los tokens.
- AWS Secrets Manager: el client secret de Cognito y la credencial SMTP.
- Amazon S3: el sitio estático del frontend, las fotos, los eventos de analytics y el state de Terraform.
- Amazon VPC: subredes privadas para las Lambdas, con Gateway Endpoints a S3 y DynamoDB y un security group.
- AWS IAM: el LabRole del lab, que es el rol de ejecución de todas las Lambdas.
- Amazon CloudWatch: los logs de cada Lambda, métricas y alarmas sobre las colas.
- AWS X-Ray: el tracing de las Lambdas.
- AWS Shield Standard: protección contra ataques de red, activa por defecto en API Gateway y S3.
- Amazon GuardDuty: detección de amenazas a nivel cuenta (actividad anómala en la API, en el DNS y en la red de las Lambdas).

Fuera de AWS, el frontend usa Google Maps para la ubicación de cada solicitud y para elegir las
zonas de un profesional, y los mails salen por SMTP a un proveedor externo (Mailtrap en la demo).

## Cómo se comunican

El frontend es un sitio estático en S3. Cuando arranca lee un config.json que sube Terraform
con la URL de la API y los datos de Cognito, así el mismo build sirve para cualquier cuenta.

Para entrar, el navegador redirige a la Hosted UI de Cognito. Después del login, Cognito vuelve
a /callback en API Gateway, que invoca a la Lambda auth-callback. Esa función cambia el código
de autorización por los tokens (se autentica contra Cognito con el client secret que lee de
Secrets Manager) y redirige al frontend con los tokens. La Hosted UI solo acepta un callback con
HTTPS y el sitio en S3 es HTTP, por eso el callback está en API Gateway y no en el sitio. Por lo
mismo no armamos una pantalla de login propia con la API de Cognito. Sin HTTPS en el sitio, la
contraseña se tipearía en una página sin cifrar.

Con el token, el navegador ya puede llamar a la API. API Gateway valida el token contra Cognito
antes de invocar cualquier Lambda, aplica throttling y manda cada ruta a la Lambda de su dominio
(catálogos, usuarios, solicitudes, flujo, calificaciones o fotos). Cognito solo dice quién es el
usuario. Si es cliente o profesional se guarda en DynamoDB, y por eso el registro tiene dos
pasos. La cuenta se crea en la Hosted UI, y el perfil (nombre, rol, categorías y zonas) se
completa con una llamada a la API la primera vez que el usuario entra.

Las fotos no pasan por la API. El backend firma una URL y el navegador sube o baja el archivo
directo a S3. Antes de subirla, el navegador achica y comprime la foto, así que llega con unos
cientos de KB. El backend igual acepta hasta 50 MB por foto, como resguardo.

Hay Lambdas que no se llaman por HTTP sino que las dispara otro servicio. Cognito invoca a
pre-signup en cada alta, para confirmar la cuenta sin mandar un mail de verificación. S3 invoca
a foto-subida cuando termina de llegar una foto, y esa función la registra en su solicitud. Las
de eventos se explican abajo.

## Eventos

Cada vez que una solicitud se crea, cambia de estado o se califica, se genera un evento. Ninguna
Lambda lo publica a mano. La tabla tiene DynamoDB Streams, y un EventBridge Pipe toma cada cambio
de la solicitud y lo publica en un topic de SNS.

No lo publica la Lambda flujo después de escribir por dos motivos. SNS no tiene Gateway Endpoint,
así que flujo (dentro de la VPC, sin salida a internet) necesitaría un Interface Endpoint pago. Y
sería una doble escritura sin atomicidad. Si la Lambda fallara entre la transacción y el publish,
el dato quedaría guardado y el evento perdido. Con el Stream, si el cambio está en la tabla, el
evento sale.

Del topic salen tres consumidores. Cada suscripción tiene un filtro, así a cada Lambda le llega
solo lo que le importa.

- analytics: guarda todos los eventos para consultarlos con Athena.
- notif-cliente: avisa por mail a la otra parte de cada cambio de estado.
- matcher: avisa a los profesionales cuando aparece un trabajo para ellos.

No pusimos una cola delante de cada Lambda. SNS invoca a una Lambda de forma asincrónica, con
una cola interna, reintentos y un destino para los fallos. Una cola SQS explícita va donde se
justifica. En analytics, para procesar en lotes. En los mails, para frenar contra el límite de
envíos del proveedor.

Cada cola tiene su DLQ, y cada Lambda invocada por SNS tiene un destino de fallo a otra DLQ. Un
mensaje que agota los reintentos queda ahí en vez de perderse, y una alarma de CloudWatch avisa
apenas aparece uno. Otra alarma avisa si una cola tiene mensajes de más de 15 minutos. Las alarmas
publican en un topic de SNS (barriofix-alarmas), que las manda por mail si se configura una dirección.

## Notificaciones por mail

notif-cliente decide a quién avisar. Al cliente cuando un profesional acepta, empieza, resuelve o
libera su solicitud, y al profesional asignado cuando el cliente cancela. Busca el email en el
perfil y arma el mail.

Como lee DynamoDB, está dentro de la VPC, y SQS tampoco tiene Gateway Endpoint. Entonces no
encola el mail sino que lo devuelve, y el destino on-success de la invocación lo deja en la cola
de mails. Esa entrega la hace el servicio Lambda, no la función, así que no necesita salir de la
VPC.

De la cola los toma enviar-email, la única función que manda mails. Va fuera de la VPC porque
habla con el proveedor SMTP por internet, y no toca ningún dato. Todo lo que necesita viene en el
mensaje. La cantidad de envíos en paralelo la limita el event source mapping, y lo que no llega a
salir espera en la cola. La credencial SMTP está en Secrets Manager y la carga el pipeline, así
que no pasa por el código ni por el state de Terraform. Sin credencial, la función simula los
envíos y los deja en el log.

No usamos SES. En el lab, el LabRole tiene denegado explícitamente mandar mails con SES, y no se
pueden crear usuarios IAM, que es de donde salen sus credenciales SMTP. En una cuenta normal,
pasar a SES sería cambiar solo enviar-email.

## Matcher y zonas

Cuando una solicitud queda disponible (se crea o un profesional la libera), el matcher busca los
profesionales disponibles que ofrecen esa categoría y cubren esa zona, y les manda un aviso. Al
que la acaba de liberar no le avisa. Igual que notif-cliente, devuelve los mails y el destino
on-success los lleva a la cola.

Para encontrarlos sin recorrer toda la tabla hay un cuarto índice, profesionales_por_categoria.
El perfil guarda las categorías como un conjunto, y DynamoDB no puede indexar un valor que está
adentro de un conjunto. Por eso el registro escribe además un ítem chico por cada categoría del
profesional, con la categoría como clave del índice, sus zonas y su email. El perfil y esos ítems
se escriben en una sola transacción. El matcher hace una consulta por categoría y filtra por zona
y disponibilidad.

Las zonas del profesional salen del mismo catálogo que las de las solicitudes, así el matching es
por id. En el registro, los barrios de CABA se eligen tocando su polígono en el mapa (el GeoJSON
de barrios de los datos abiertos de la Ciudad, simplificado) y los partidos del AMBA con botones.
No dejamos que el profesional dibuje un área libre, porque habría que comparar coordenadas, y
DynamoDB no resuelve eso solo. La zona decide a quién se avisa, no quién puede tomar el trabajo.

## Analytics

La Lambda analytics lee su cola en lotes de hasta 100 eventos y los escribe en S3 como JSON, un
objeto por día en carpetas por fecha. Una tabla de Glue describe esos archivos, y Athena los
consulta con SQL. La tabla calcula las particiones sola a partir de la fecha (partition
projection), así que no hace falta un crawler, que además pediría un rol propio. Hay tablas
chicas con los nombres de categorías, zonas, urgencias y usuarios, para que los resultados no
muestren ids.

Las consultas de negocio quedan guardadas en un workgroup de Athena. Fill rate a 48 horas por
zona, combinaciones de categoría y zona donde los trabajos no se toman, el funnel de creada a
calificada, profesionales que aceptan y sueltan trabajos, cancelaciones según el estado desde el
que se cancela, y si la urgencia declarada realmente acelera la aceptación.

CloudWatch queda para la salud del sistema (errores, colas, alarmas), no para métricas de
negocio, que son preguntas que cambian y se cruzan por zona, profesional o fecha. No usamos
Kinesis porque el volumen no lo justifica, ni Firehose porque la Lambda ya escribe directo a S3
por el Gateway Endpoint. QuickSight y Grafana administrado no están disponibles en el lab.

Los datos de demo incluyen un histórico de 80 solicitudes. Terraform las carga en DynamoDB y
arma sus eventos en S3 a partir del mismo seed, así lo que se ve en la app coincide con lo que
devuelve Athena desde el primer deploy.

## Datos

Usamos una sola tabla, con PK y SK, y cuatro índices secundarios. Uno para las solicitudes de un
cliente, otro para las asignadas a un profesional, otro para los trabajos pendientes de cada
categoría y otro para los profesionales de cada categoría. Los tres últimos son sparse, o sea que
un ítem solo aparece en el índice mientras tiene ese atributo. Una solicitud deja de estar en
pendientes apenas alguien la toma.

El estado de cada solicitud se guarda en el mismo ítem y se actualiza con transacciones. Para
que dos profesionales no tomen el mismo trabajo no usamos bloqueos. La escritura es condicional
sobre el estado, y si otro llegó primero, falla.

Los catálogos, los usuarios de demo con sus zonas y el histórico de solicitudes los carga
Terraform como seed.

## Red

Las Lambdas que tocan datos están en subredes privadas sin NAT ni Internet Gateway. Llegan a
DynamoDB y a S3 por Gateway Endpoints, que no cuestan nada, y las policies de esos endpoints solo
permiten la tabla y los buckets del proyecto (en el de analytics, solo escribir eventos). Si
alguna función quedara comprometida, no tendría a dónde sacar los datos.

Solo dos funciones corren fuera de la VPC, porque necesitan internet y ninguna toca datos.
auth-callback, que llega a Cognito, y enviar-email, que llega al proveedor SMTP.

En el TP2 teníamos RDS y un nivel de subredes solo para la base. DynamoDB es un servicio
regional que no vive dentro de la VPC, así que ese nivel ya no hace falta y quedó un solo nivel
de subredes privadas.

## Seguridad

En el Learner Lab no se pueden crear roles, y todas las Lambdas usan LabRole, que tiene permisos
amplios. Entonces el mínimo privilegio lo aplicamos por otro lado. A nivel red, con las policies
de los endpoints. A nivel recursos, con la bucket policy del front, una resource policy opcional
en DynamoDB que solo acepta tráfico que venga del endpoint de la VPC, la policy de la cola de
analytics (solo acepta mensajes del topic de eventos) y los permisos de invocación de cada
Lambda, que dicen exactamente qué servicio puede llamarla.

Las URLs firmadas para las fotos tienen condiciones (tamaño máximo, solo imágenes y la key
exacta). Los endpoints que no pueden pedir login, el callback y los catálogos, están cubiertos
por el throttling de API Gateway, y auth-callback además tiene concurrencia reservada, para que
un flood no se coma el límite de concurrencia de toda la cuenta.

No pusimos WAF. Solo se puede asociar a una REST API, a CloudFront o a un load balancer, no a una
HTTP API, y CloudFront no está en el lab. Elegimos HTTP API por simple, más barata y con el
authorizer de Cognito incluido, y cubrimos el abuso con throttling.

Como capa de detección sumamos GuardDuty, que mira la actividad de la cuenta en busca de algo
anómalo sin que las Lambdas tengan que llamarlo. Dejamos escritos pero apagados Inspector, Config y
Security Hub: verificamos que el lab los bloquea (Inspector no está permitido, y Config no puede
asumir el LabRole), pero quedan listos para una cuenta normal.

## Lo que marca el análisis estático

El tfsec del template y el code scanning de GitHub marcan algunas cosas que dejamos así a
propósito, y cada una tiene su comentario en el código.

El bucket del frontend es público porque sirve el sitio, pero la policy solo permite leer. No se
puede escribir ni listar. La contra es que no hay HTTPS directo ni CDN adelante. Tampoco tiene
versionado, porque el sitio se vuelve a subir entero en cada deploy.

Para cifrar en reposo usamos las llaves que administra AWS, no llaves propias de KMS, en
DynamoDB, Secrets Manager, S3, SQS y CloudWatch. Una llave propia no cifra mejor. Daría más
control (rotación, auditoría de cada uso), pero en el lab ese control no se aprovecha porque todo
usa LabRole, y una policy de llave mal puesta puede dejarnos sin acceso a los datos. Los topics
de SNS no tienen cifrado porque SNS solo cifra con KMS, y la llave que administra AWS no deja
publicar a EventBridge ni a CloudWatch. Los mensajes viajan por TLS y no llevan secretos.

Tampoco activamos point in time recovery en DynamoDB ni los access logs de API Gateway. Para
esta entrega no justifican el costo, y con los logs de las Lambdas alcanza. Las Lambdas sí
tienen el tracing de X-Ray activado.

Los detalles de Terraform (módulos, funciones y meta-argumentos) están en
[terraform.md](terraform.md).
