# Runbook: Rotación de secretos (Docker secrets)

Cada secreto del inventario (`SECURITY.md` → *Inventario de secretos*) se rota reemplazando el
archivo en `infra/secrets/`, recreando los servicios que lo consumen y verificando que arrancan
leyéndolo desde `/run/secrets/`. El valor viejo queda revocado cuando deja de existir en el store.

## Cuándo usarlo

- Rotación programada (trimestral o según política de seguridad).
- Respuesta a un incidente de seguridad (posible compromiso).
- Cambio de credenciales tras la salida de un miembro del equipo.

## Prerrequisitos

- Los secretos viven en `infra/secrets/` (git-ignored).
- Docker Compose está operativo.
- Todos los servicios están healthy antes de la rotación.
- **Generador de valores**: si el host no tiene `openssl`, usar el fallback de `/dev/urandom` que se
  indica en cada paso (fue el caso durante el ensayo de S5-P1-01).

## Patrón general (todos los secretos)

```bash
cd infra
cp secrets/<secreto> secrets/<secreto>.bak          # respaldo para rollback
# ... generar el nuevo valor (ver cada secreto) ...
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate <servicios>
sleep 15
docker compose -f compose/docker-compose.yml --env-file .env ps --format '{{.Name}}\t{{.Status}}'
```

Regla: nunca escribir el valor en un archivo trackeado; `docker compose config` solo debe mostrar
referencias (`*_FILE` / `secrets:`).

---

## 1. `minio_webhook_secret` (secreto compartido MinIO → doc-service)

Consumidores: `minio` (auth_token del webhook), `doc-service` (validación `Bearer`) y
`minio-notify-init`. Es el de menor blast radius para practicar (no toca datos persistidos).

```bash
cd infra
cp secrets/minio_webhook_secret.txt secrets/minio_webhook_secret.txt.bak
# 32 hex + salto de linea (33 bytes):
{ head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo; } > secrets/minio_webhook_secret.txt
#   (equivalente con openssl si esta disponible: openssl rand -hex 16 > secrets/minio_webhook_secret.txt)

docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate minio doc-service
sleep 12
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate minio-notify-init
```

Verificar (sin imprimir el valor):

```bash
# 1) Mismo valor en archivo, MinIO (PID1) y doc-service (PID1): comparar sha256.
docker exec infra-minio-1 sh -c 'tr "\0" "\n" < /proc/1/environ' | grep MINIO_NOTIFY_WEBHOOK_AUTH_TOKEN_DOCSERVICE
docker exec infra-doc-service-1 sh -c 'tr "\0" "\n" < /proc/1/environ' | grep MINIO_WEBHOOK_SECRET
# 2) Revocación: el token viejo debe dar 401 y el nuevo no.
#    (usar .bak como viejo y el archivo actual como nuevo; ver evidencia S5-P1-06)
```

Resultado esperado (ensayo S5-P1-01): token viejo → `HTTP 401`, token nuevo → `HTTP 200`,
MinIO/doc-service healthy y `minio-notify-init` reporta el target activo.

Rollback: `cp secrets/minio_webhook_secret.txt.bak secrets/minio_webhook_secret.txt` y recrear los
tres servicios.

## 2. `redis_streams_password` (+ variante JSON)

Consumidores: `redis-streams`, réplicas, `sentinel-*`, `doc-service`, `extraction-worker` y
`redis-exporter` (JSON). Rotarlos todos juntos.

```bash
cd infra
cp secrets/redis_streams_password.txt secrets/redis_streams_password.txt.bak
{ head -c 24 /dev/urandom | base64 | tr -d '\n'; echo; } > secrets/redis_streams_password.txt
# IMPORTANTE: regenerar el JSON del exporter con el MISMO valor nuevo, la clave es la URI completa.
NEW=$(tr -d '\n' < secrets/redis_streams_password.txt)
printf '{"redis://redis-streams:6379": "%s"}\n' "$NEW" > secrets/redis_streams_password.json
unset NEW

docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate \
  redis-streams redis-streams-replica-1 redis-streams-replica-2 \
  sentinel-1 sentinel-2 sentinel-3 redis-exporter doc-service extraction-worker
```

Verificar: `redis-cli -a "$(cat /run/secrets/redis_streams_password)" ping` → `PONG`; y
`redis_up 1` en `http://redis-exporter:9121/metrics` (red `infra_data`).

Si la clave del JSON no coincide con la URI, el exporter arranca pero falla con `NOAUTH` y
`redis_up 0`: el secreto se ignora en silencio.

## 3. `minio_root_password`

```bash
cd infra
cp secrets/minio_root_password.txt secrets/minio_root_password.txt.bak
{ head -c 24 /dev/urandom | base64 | tr -d '\n'; echo; } > secrets/minio_root_password.txt
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate minio
# Si los jobs ya corrieron, tambien: minio-init y minio-notify-init
```

## 4. `mongo_initdb_root_password`

El password root se usa al inicializar el RS. Para rotarlo hay que cambiarlo en la base **y**
actualizar el archivo (en ese orden), si no el healthcheck deja de autenticar:

```bash
cd infra
cp secrets/mongo_initdb_root_password.txt secrets/mongo_initdb_root_password.txt.bak
NEW=$({ head -c 24 /dev/urandom | base64 | tr -d '\n'; })
docker exec infra-mongo-1 mongosh \
  -u "$(grep -E '^MONGO_INITDB_ROOT_USERNAME=' .env | cut -d= -f2)" \
  -p "$(cat secrets/mongo_initdb_root_password.txt)" \
  --authenticationDatabase admin \
  --eval "db.updateUser('$(grep -E '^MONGO_INITDB_ROOT_USERNAME=' .env | cut -d= -f2)', {pwd: '$NEW'})"
printf '%s\n' "$NEW" > secrets/mongo_initdb_root_password.txt
unset NEW
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate mongo mongo-init
```

## 5. `mongo_app_password` / `mongo_worker_password`

Estos usuarios los crea `mongo/init.js`; `upsertUser` **no** resetea el password si los roles ya son
correctos. Por eso la rotación cambia el password en la base y luego el archivo:

```bash
cd infra
USER=$(grep -E '^MONGO_WORKER_USER=' .env | cut -d= -f2)   # o MONGO_APP_USER
cp secrets/mongo_worker_password.txt secrets/mongo_worker_password.txt.bak
NEW=$({ head -c 24 /dev/urandom | base64 | tr -d '\n'; })
docker exec infra-mongo-1 mongosh \
  -u "$(grep -E '^MONGO_INITDB_ROOT_USERNAME=' .env | cut -d= -f2)" \
  -p "$(cat secrets/mongo_initdb_root_password.txt)" \
  --authenticationDatabase admin \
  --eval "db.getSiblingDB('documents').changeUserPassword('$USER', '$NEW')"
printf '%s\n' "$NEW" > secrets/mongo_worker_password.txt   # o mongo_app_password.txt
unset NEW
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate \
  extraction-worker doc-service     # segun el usuario rotado
```

Verificar: `readyz` del worker (`{"checks":{"mongo":"ok"}}`) o `healthz` de doc-service.

## 6. `mongo_keyfile`

Cambiar el keyFile exige reiniciar el RS (en este stack: un solo nodo). Requiere `chown` a `999:999`
(usuario de `mongod`), por lo que necesita privilegios de root en el host.

```bash
cd infra
cp secrets/mongo_keyfile secrets/mongo_keyfile.bak   # puede requerir sudo por el modo 400
docker compose -f compose/docker-compose.yml --env-file .env stop mongo
{ head -c 756 /dev/urandom | base64 | tr -d '\n'; echo; } > secrets/mongo_keyfile
sudo chown 999:999 secrets/mongo_keyfile && sudo chmod 400 secrets/mongo_keyfile
docker compose -f compose/docker-compose.yml --env-file .env up -d mongo
```

Sin apertura de RS no se admite un keyfile nuevo: reiniciar el nodo con el keyfile anterior si el
arranque falla (rollback con `.bak`).

## 7. `internal_token`, `grafana_admin_password`, credenciales S3 por servicio

Patrón `*_FILE` estándar:

```bash
cd infra
cp secrets/internal_token.txt secrets/internal_token.txt.bak
{ head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n'; echo; } > secrets/internal_token.txt
docker compose -f compose/docker-compose.yml --env-file .env up -d --force-recreate doc-service
```

`grafana_admin_password` → recrear `grafana`. Las claves `svc_*` de MinIO → recrear el servicio y
`minio-init` si hace falta re-aplicar usuarios/políticas.

## 8. Traefik / ACME

La variante local usa certificados `mkcert` en `traefik/certs/` (git-ignored), no ACME. **No hay
credenciales ACME en el repo.** Al habilitar ACME en producción: el email del resolver es
configuración (no secreto) y cualquier token de proveedor DNS-01 debe entrar como Docker secret y
rotarse desde el panel del proveedor. Pendiente hasta que se active ACME.

## Frecuencia recomendada

- Passwords de base de datos: cada 90 días.
- API keys / tokens: cada 180 días.
- Tras incidente de seguridad: inmediato.

## Evidencia

Ver `docs/evidencias/S5/S5-P1-06-secretos.txt` para la rotación practicada de
`minio_webhook_secret` (S5-P1-01). La rotación de prueba previa de `redis_streams_password` está en
`docs/evidencias/S2/S2-P1-01-secrets.txt`.
