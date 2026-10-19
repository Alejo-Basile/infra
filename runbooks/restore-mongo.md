# Runbook: Restauración de MongoDB

## Cuándo usarlo

- Pérdida de datos o corrupción en el Replica Set `rs0`.
- Recuperación tras fallo de disco o eliminación accidental.
- Prueba de que un backup es válido (restore en contenedor limpio).

## Prerrequisitos

- Un archive válido generado con `mongodump --oplog`.
- Docker disponible.
- Red `infra_data` operativa.

## Procedimiento

### 1. Snapshot (con oplog)

```bash
set -a && source .env && set +a

docker exec infra-mongo-1 mongodump \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin \
  --oplog --archive=/tmp/mongo-backup-$(date +%F-%H%M).archive

docker cp infra-mongo-1:/tmp/mongo-backup-*.archive /tmp/
```

El `--oplog` permite restaurar con `--oplogReplay`, preservando el estado exacto del momento del dump.

### 2. Restaurar en contenedor limpio

```bash
# Crear volumen nuevo (no tocar el vivo)
docker volume create infra_mongo-restore-test

# Arrancar contenedor limpio
docker run -d \
  --name infra-mongo-restore-test \
  --network infra_data \
  -v infra_mongo-restore-test:/data/db \
  mongo:7.0

# Esperar que esté listo (~10s)
sleep 10

# Copiar el archive al contenedor
docker cp /tmp/mongo-backup-<timestamp>.archive infra-mongo-restore-test:/tmp/

# Restaurar
docker exec infra-mongo-restore-test \
  mongorestore --archive=/tmp/mongo-backup-<timestamp>.archive --oplogReplay
```

### 3. Verificar integridad

```bash
# Conteo de documentos por colección en el vivo:
docker exec infra-mongo-1 mongosh \
  -u "$MONGO_INITDB_ROOT_USERNAME" -p "$MONGO_INITDB_ROOT_PASSWORD" \
  --authenticationDatabase admin --quiet \
  --eval 'db.getSiblingDB("documents").documents.countDocuments({})'

# Conteo en el restaurado:
docker exec infra-mongo-restore-test mongosh --quiet \
  --eval 'db.getSiblingDB("documents").documents.countDocuments({})'
```

Los conteos deben coincidir. Si difieren, el backup es incompleto.

### 4. Promover el restaurado (opcional)

Si el contenedor original está irrecuperable, apuntar la aplicación al contenedor restaurado:

```bash
# Actualizar la connection string en el compose o en las variables de entorno.
# El contenedor restaurado usa el mismo puerto 27017 y la misma red infra_data.
```

### 5. Limpiar el contenedor de prueba

```bash
docker rm -f infra-mongo-restore-test
docker volume rm infra_mongo-restore-test
```

## Frecuencia recomendada

- Snapshot diario (cron a las 03:00).
- Verificación semanal (restore en contenedor limpio + conteo).
- Retención de 7 días de archives en `/tmp` (o en un bucket externo).

## Rollback

N/A. El restore es en un contenedor aparte. Si falla, se limpia el volumen y se reintenta con otro archive.

## Evidencia

Ver `docs/evidencias/S2/S1-P1-14-restore.txt` para un ejemplo verificado con conteos.
