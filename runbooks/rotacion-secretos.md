# Runbook: Rotación de secretos (Docker secrets)

## Cuándo usarlo

- Rotación programada (trimestral o según política de seguridad).
- Respuesta a un incidente de seguridad ( posible compromise).
- Cambio de credenciales tras la salida de un miembro del equipo.

## Prerrequisitos

- Los secretos viven en `infra/secrets/` (git-ignored).
- Docker Compose está operativo.
- Todos los servicios están healthy antes de la rotación.

## Procedimiento

### 1. Generar el nuevo valor

```bash
openssl rand -base64 24 > secrets/redis_streams_password.txt
```

Para MinIO access keys (alfanuméricos):
```bash
openssl rand -base64 30 | tr -dc 'a-zA-Z0-9' | head -c 20 > secrets/svc_docservice_access_key.txt
openssl rand -base64 60 | tr -dc 'a-zA-Z0-9' | head -c 40 > secrets/svc_docservice_secret_key.txt
```

### 2. Reemplazar el archivo

```bash
# El archivo ya se actualizó con openssl (ver paso 1).
# Verificar que tiene contenido:
cat secrets/redis_streams_password.txt | wc -c   # debe ser ~33
```

### 3. Recrear los servicios que usan ese secreto

Para `redis_streams_password` (lo usan redis-streams, réplicas, sentinels y redis-exporter):
```bash
set -a && source .env && set +a
docker compose -f compose/docker-compose.yml --env-file .env up -d \
  redis-streams redis-streams-replica-1 redis-streams-replica-2 \
  sentinel-1 sentinel-2 sentinel-3 redis-exporter
```

Para `minio_root_password`:
```bash
docker compose -f compose/docker-compose.yml --env-file .env up -d minio
```

Para `mongo_initdb_root_password`:
```bash
# Volumen de mongo: el password root se usa al inicializar el RS.
# Si solo se cambia el password, actualizar el usuario en la base:
docker exec infra-mongo-1 mongosh \
  -u "$MONGO_INITDB_ROOT_USERNAME" \
  -p "$(cat /run/secrets/mongo_initdb_root_password)" \
  --authenticationDatabase admin \
  --eval 'db.updateUser("'$MONGO_INITDB_ROOT_USERNAME'", {pwd: "nuevo_password_aqui"})'
# Luego actualizar el archivo y recrear mongo.
```

### 4. Verificar que el servicio lee el nuevo valor

```bash
# Verificar que los servicios quedaron healthy:
sleep 15
docker compose -f compose/docker-compose.yml --env-file .env ps --format '{{.Name}}\t{{.Status}}'

# Verificar que redis-streams responde con el nuevo password:
docker exec infra-redis-streams-1 redis-cli \
  -a "$(cat secrets/redis_streams_password.txt)" \
  --no-auth-warning ping
# Debe devolver PONG
```

### 5. Rollback si algo falla

```bash
# Revertir al valor anterior (si lo tenés guardado):
cp secrets/redis_streams_password.txt.bak secrets/redis_streams_password.txt
docker compose -f compose/docker-compose.yml --env-file .env up -d redis-streams
```

## Notas importantes

- **Coordinar dependencias**: `redis_streams_password` lo usan primario, réplicas, sentinels y redis-exporter. Rotarlos todos juntos.
- **El archivo `.json` del redis-exporter**: si rotás `redis_streams_password`, regenerar también el `secrets/redis_streams_password.json` con el formato `{"redis_password": "valor"}`.
- **No committear secretos**: van en `.gitignore`.
- **Backup antes de rotar**: guardar el valor anterior como `.bak` por si necesitás revertir.

## Frecuencia recomendada

- Passwords de base de datos: cada 90 días.
- API keys / tokens: cada 180 días.
- Tras incidente de seguridad: inmediato.

## Evidencia

Ver `docs/evidencias/S2/S2-P1-01-secrets.txt` para la rotación de prueba ejecutada.
