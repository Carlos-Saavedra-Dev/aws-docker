# Runbook — Proyecto final Computación en la Nube (AWS)

**App:** Catálogo de Productos (CRUD) — Frontend HTML/JS + API FastAPI (Python) + MySQL 8, en contenedores Docker.
**Cuenta AWS:** campus `787124623188` (usuario IAM `carlos_saavedra`) · **Región:** `us-east-1` (N. Virginia)
**Código:** carpeta `docker_ff/` (fork corregido del repo `Breinerma/docker_ff`).

## URLs en vivo

| Qué | URL |
|---|---|
| CloudFront (HTTPS, URL principal) | `https://d2e3ajuk1w1dp2.cloudfront.net` |
| S3 sitio web estático | `http://cs-docker-frontend-787124623188.s3-website-us-east-1.amazonaws.com` |
| ECS Fargate directo (nginx) | `http://98.93.195.111` (IP pública del task; cambia si la tarea se reinicia) |
| API docs (Swagger) | `https://d2e3ajuk1w1dp2.cloudfront.net/docs` |
| Health check (API + BD) | `https://d2e3ajuk1w1dp2.cloudfront.net/api/health` |

## Arquitectura

```
Usuario ──HTTPS──► CloudFront ──┬── /            ──► S3 (sitio web estático: index.html, style.css, config.js)
                                │                     bucket policy: s3:GetObject público
                                └── /api/* /docs ──► ECS Fargate task (IP pública, SG puerto 80)
                                                      ├─ nginx  (imagen ECR cs-docker:nginx) :80
                                                      ├─ api    (imagen ECR cs-docker:api)   :8000
                                                      └─ db     (mysql:8.0)                  :3306
                                                      (los 3 contenedores comparten red awsvpc → 127.0.0.1)
IAM: ecsTaskExecutionRole (AmazonECSTaskExecutionRolePolicy) → ECS puede bajar imágenes de ECR y escribir logs en CloudWatch.
```

## Errores encontrados en el código del compañero y corrección

| # | Error | Corrección |
|---|---|---|
| 1 | `nginx/default.conf` hacía `proxy_pass http://127.0.0.1:8000` → en **docker compose** cada contenedor tiene su propia IP, nginx no llegaba al API (502). | Plantilla `default.conf.template` con `${API_HOST}`: `127.0.0.1` en ECS (mismo task), `api` en compose. |
| 2 | Typo `PYTHONUNBUFFERRED` en `api/Dockerfile` (logs con buffer). | `PYTHONUNBUFFERED=1`. |
| 3 | El API reintentaba la BD solo 5×3 s; MySQL tarda 30–60 s en el primer arranque → tablas no creadas, API caído. | 40 reintentos × 3 s con `lifespan` (reemplaza `@app.on_event`, deprecado) + `pool_pre_ping`. |
| 4 | `price` era texto libre (`"abc"` válido). | `Numeric(12,2)` en BD, `Decimal > 0` en el API, `input type=number` en el front. |
| 5 | El front llamaba `/api` relativo: no funciona si el HTML se sirve desde S3. | `config.js` con URL base del API + CORS en FastAPI. |
| 6 | Sin endpoint de salud. | `GET /api/health` (verifica BD con `SELECT 1`). |
| 7 | `README.md` en UTF‑16 (ilegible) y `nginx/Dockerfile` sin uso en compose. | README nuevo; compose construye `nginx/Dockerfile`. |

## Pasos (igual que en clase, con prefijo `cs-` en lugar de `jaom-`)

> Todo se hace en **CloudShell** (consola AWS → icono `>_`, región us-east-1). El script `docker_ff/deploy/deploy.sh` automatiza cada paso; abajo está el equivalente en consola.

0. **Código en CloudShell**: `git clone https://github.com/Breinerma/docker_ff.git` y aplicar los archivos corregidos (o subir la carpeta `docker_ff`).
1. **ECR** (Elastic Container Registry → Crear repositorio privado `cs-docker`). Botón *Ver comandos de envío*:
   ```bash
   aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 787124623188.dkr.ecr.us-east-1.amazonaws.com
   docker build --no-cache --platform linux/amd64 -t cs-docker:api ./api
   docker tag cs-docker:api 787124623188.dkr.ecr.us-east-1.amazonaws.com/cs-docker:api
   docker push 787124623188.dkr.ecr.us-east-1.amazonaws.com/cs-docker:api
   docker build --no-cache --platform linux/amd64 -t cs-docker:nginx -f nginx/Dockerfile .
   docker tag cs-docker:nginx 787124623188.dkr.ecr.us-east-1.amazonaws.com/cs-docker:nginx
   docker push 787124623188.dkr.ecr.us-east-1.amazonaws.com/cs-docker:nginx
   ```
   (script: `bash deploy/deploy.sh paso1_ecr`)
2. **IAM** → Roles → Crear rol → Servicio de AWS → *Elastic Container Service Task* → política `AmazonECSTaskExecutionRolePolicy` → nombre `ecsTaskExecutionRole`. (script: `paso2_iam`)
3. **ECS → Definiciones de tareas → Crear** `cs-docker-task`: Fargate, Linux/X86_64, 1 vCPU / 3 GB, rol de ejecución `ecsTaskExecutionRole`. Contenedores:
   - `db` → imagen `public.ecr.aws/docker/library/mysql:8.0`, puerto 3306, variables `MYSQL_ROOT_PASSWORD`, `MYSQL_DATABASE=appdb`, `MYSQL_USER=appuser`, `MYSQL_PASSWORD=apppassword`.
   - `api` → imagen ECR `cs-docker:api`, puerto 8000, variables `DB_HOST=127.0.0.1`, `DB_PORT=3306`, `DB_USER=appuser`, `DB_PASSWORD=apppassword`, `DB_NAME=appdb`.
   - `nginx` → imagen ECR `cs-docker:nginx`, puerto 80 HTTP, `API_HOST=127.0.0.1`.
   - Logs: CloudWatch `/ecs/cs-docker-task`. (script: `paso3_taskdef`)
4. **ECS → Clústeres → Crear** `cs-cluster-produccion` (AWS Fargate). (script: `paso5_ecs`)
5. **Crear servicio** `cs-docker-task-service` en el clúster: familia `cs-docker-task`, 1 tarea, VPC por defecto, todas las subredes, **grupo de seguridad nuevo `cs-docker-sg` con HTTP 80 desde 0.0.0.0/0**, **IP pública activada**. Esperar estado *RUNNING* → pestaña Tareas → Configuración → IP pública. (script: `paso5_ecs`)
6. **S3**: bucket `cs-docker-frontend-787124623188` → Propiedades → *Alojamiento de sitios web estáticos* (index `index.html`) → Permisos → desactivar "Bloquear acceso público" para políticas → **Política del bucket**:
   ```json
   {"Version":"2012-10-17","Statement":[{"Sid":"PublicReadGetObject","Effect":"Allow","Principal":"*",
     "Action":"s3:GetObject","Resource":"arn:aws:s3:::cs-docker-frontend-787124623188/*"}]}
   ```
   Subir `frontend/` (index.html, style.css, config.js con `API_URL_DIRECTA = http://<DNS público del task>`). (script: `paso6_s3`)
7. **CloudFront → Crear distribución**: origen 1 = endpoint de sitio web S3 (HTTP), origen 2 = DNS público del task ECS (HTTP 80). Comportamientos: `Default (*)` → S3 (CachingOptimized); `/api/*`, `/docs*`, `/openapi.json` → ECS (CachingDisabled, AllViewerExceptHostHeader, todos los métodos). Viewer: Redirect HTTP→HTTPS. (script: `paso7_cloudfront`) — tarda ~5–10 min en *Deployed*.
8. **Verificar**: abrir URL de CloudFront, crear / editar / eliminar un producto; `…/api/health` devuelve `{"status":"ok","db":"ok"}`.

## Probar en local
```bash
cd docker_ff
docker compose up -d --build     # http://localhost   (API en http://localhost/docs)
docker compose down -v
```

## Costos y apagado (después de la calificación)
- Lo único que cobra por hora es la tarea Fargate (~US$0.06/h). Apagar: ECS → servicio → *Actualizar* → tareas deseadas = 0 (o `aws ecs update-service --cluster cs-cluster-produccion --service cs-docker-task-service --desired-count 0`).
- S3, ECR, CloudFront: centavos / capa gratuita.
- ⚠️ Si la tarea se reinicia cambia la IP pública → hay que actualizar el origen ECS de CloudFront y `config.js` (re-ejecutar `paso6_s3`). Para producción real se usaría un Application Load Balancer y RDS en lugar de MySQL en el mismo task (los datos se pierden si la tarea se reinicia).

## Actualizar la app (nueva versión del front / imagen)
```bash
cd ~/docker_ff
R=787124623188.dkr.ecr.us-east-1.amazonaws.com/cs-docker
docker build --platform linux/amd64 -t cs-docker:nginx -f nginx/Dockerfile . && docker tag cs-docker:nginx $R:nginx && docker push $R:nginx
aws ecs update-service --cluster cs-cluster-produccion --service cs-docker-task-service --force-new-deployment
aws ecs wait services-stable --cluster cs-cluster-produccion --services cs-docker-task-service
NEWDNS=$(bash deploy/deploy.sh ecs_dns | awk '{print $2}')
bash deploy/cf_origin.sh $NEWDNS        # CloudFront apunta al nuevo task + invalidación /*
bash deploy/deploy.sh paso6_s3          # S3 con el nuevo config.js / estilos
```
(El reinicio crea un task nuevo: cambia la IP pública y la BD empieza vacía.)
