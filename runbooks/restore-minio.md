# Runbook: Restauración de MinIO (buckets raw-pdfs y extracted-txt)

## Cuándo usarlo
Restauración de objetos de MinIO tras corrupción/pérdida, como rama de datos del rollback de cutover (S9-X-01 §6).

## Prerrequisitos
- Stack `full` levantado.
- Destino de backup **provisionado y programado** (ver Limitaciones).
- Writers detenidos (`doc-service`, `extraction-worker`).
- Credenciales por servicio reutilizadas (docs/SPEC.md §9, infra/SECURITY.md). Nunca restaurar credenciales root de MinIO.

## Destino de backup (concreto)
`BACKUP_DEST` = `/srv/backups/minio` en el host (overridable con `MINIO_BACKUP_DIR`), montado como `/backup` dentro del contenedor efímero `minio/mc`. Cada corrida crea `/srv/backups/minio/<YYYY-MM-DD>/` con `raw-pdfs/` y `extracted-txt/`.

## Estado instalado en este host (2026-11-17)
- Cron de usuario **instalado y activo**: diario 03:17 UTC, `MODE=exec` (la imagen `minio/mc` no se puede pullear aquí), `MINIO_BACKUP_DIR=/home/alejobasilesoca/minio-backups`, log en el mismo directorio.
- Primer backup real: snapshot `2026-11-17/`, 1.4 GB, 6 s, paridad 300/300 (`raw-pdfs`) y 3138/3138 (`extracted-txt`). Evidencia: `infra/docs/evidencias/S9/S9-P1-01-backup-destino.txt`.
- `/srv/backups/minio` **no** está provisionado: requiere `sudo`. Mientras no exista, el destino es el directorio del home. Para moverlo:
  ```bash
  sudo mkdir -p /srv/backups/minio && sudo chown "$USER" /srv/backups/minio
  crontab -e   # MINIO_BACKUP_DIR=/srv/backups/minio
  ```

## Limitaciones
El destino se provisiona por el operador y NO está dentro del repo. El perfil `full` de compose no incluye ningún servicio de backup. Instalar el cron con `infra/scripts/install-minio-backup-cron.sh`. En este host el cron instalado apunta al home por falta de `sudo`. Retención: 14 snapshots diarios (~20 GB con el volumen actual); el prune es automático vía `RETENTION_DAYS` (default 14).

## Paso 0 — Configurar alias `myminio`
```bash
docker exec infra-minio-1 mc alias set myminio http://localhost:9000 <MINIO_ADMIN_USER> <MINIO_ADMIN_PASSWORD>
```
Estas son credenciales **administrativas** de MinIO, usadas solo para backup/restore; nunca las claves por servicio de la aplicación. Si el host expone `/proc`, evitar pasarlas en `argv`: usar un archivo temporal de credenciales dentro del contenedor y eliminarlo después.

## Backup (producción del respaldo)

### Provisionar el destino
1. Crear el directorio host: `mkdir -p /srv/backups/minio` (o el valor de `MINIO_BACKUP_DIR`).
2. Asegurar ownership/permisos para el usuario que ejecuta el cron.
3. Verificar espacio disponible: los buckets suman ~1.5 GiB hoy; dimensionar con margen.

### Instalar el cron
Instalar con `infra/scripts/install-minio-backup-cron.sh` (host cron, no contenedor), con `MAILTO=""` y log en `<dest>/backup.log`.

### Ejecutar manualmente
`infra/scripts/minio-backup.sh` (DEST_DIR por defecto `/srv/backups/minio`).

### Ejecutar en modo preview
`DRY_RUN=1 infra/scripts/minio-backup.sh` imprime los comandos `mc mirror` sin ejecutarlos.

### Limitación honesta
El destino es provisionado por el operador y NO está dentro del repo; el perfil `full` de compose no incluye ningún servicio de backup. El cron está instalado y activo en este host (diario 03:17 UTC, `MODE=exec`, destino home). Verificar con `infra/scripts/install-minio-backup-cron.sh --check`. El ensayo de restore MinIO (`S9-X-01-B3`) está medido (RTO ~20.5 s).

## Procedimiento de restore
```bash
# 1. Detener writers
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml --profile full stop doc-service extraction-worker
# 2. Restaurar (mc dentro de infra-minio-1)
docker exec infra-minio-1 mc mirror --overwrite /backup/raw-pdfs myminio/raw-pdfs
docker exec infra-minio-1 mc mirror --overwrite /backup/extracted-txt myminio/extracted-txt
# 3. Verificar
docker exec infra-minio-1 mc ls --recursive --summarize myminio/raw-pdfs
docker exec infra-minio-1 mc ls --recursive --summarize myminio/extracted-txt
docker exec infra-minio-1 mc stat myminio/raw-pdfs/<sample>
docker exec infra-minio-1 mc cat myminio/raw-pdfs/<sample> | head -c 5   # esperado: %PDF-
# 4. Reiniciar y reconciliar
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml --profile full start doc-service extraction-worker
```

## Reconciliación post-restore (docs/SPEC.md §6.5)
`HEAD` de objetos pendientes, reencolar `UPLOADED`, no borrar nada.

## Prueba final
Una transacción completa end-to-end como prueba final.

RTO: medido y declarado por corrida, nunca prometido.

## RTO medido (2026-11-17)

- Procedimiento usado: snapshot copiado al contenedor con `docker cp ... infra-minio-1:/tmp/drill-raw` y `/tmp/drill-extracted`; buckets scratch `drill-raw-pdfs` y `drill-extracted-txt` creados con `mc mb`; mirror con `mc mirror` dentro de `infra-minio-1`.
- Mirror duration: 20470 ms (1.32 GiB, 300 + 3138 objetos).
- Verificacion: drill-raw-pdfs=300, drill-extracted-txt=3138; spot check primeros 5 bytes `%PDF-`.
- Limpieza: `mc rb --force` de ambos buckets scratch y `rm -rf /tmp/drill-raw /tmp/drill-extracted` (parcialmente bloqueado por permisos dentro del contenedor, sin impacto en datos vivos). Buckets vivos verificados: raw-pdfs=300, extracted-txt=3138.
