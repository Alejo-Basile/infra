# Runbook: espacio de disco de MinIO

Aplica a las alertas del grupo `s1-p1-13-infra`:

| Alerta | Severidad | Condicion | Tiempo |
| --- | --- | --- | --- |
| `MinioDiskHigh` | warning | uso > 70 por ciento | 5m |
| `MinioDiskCritical` | critical | uso > 85 por ciento | 5m |

Origen de la tarea: S5-P1-04 (`docs/plan-P1.md` §3.6). La regla original usaba
`minio_cluster_disk_used_bytes / minio_cluster_disk_total_bytes`, metricas que
**no existen** en `minio 2025.7.23`; la alerta era NoData permanente. La expresion
vigente es:

```
1 - (minio_cluster_capacity_usable_free_bytes / minio_cluster_capacity_usable_total_bytes)
```

## Que mide realmente

`usable_total` es el filesystem que respalda el volumen `minio-data`, **no** una
cuota propia de MinIO. En este stack coincide con el disco del host
(100.06 GB observados), asi que la alerta tambien se dispara por presion de disco
del host (imagenes Docker, logs, build cache) y no solo por crecimiento de buckets.

Separa las dos causas antes de actuar:

```bash
# 1. Uso que ve MinIO (capacidad del filesystem)
docker exec infra-minio-1 curl -s http://127.0.0.1:9000/minio/v2/metrics/cluster \
  | grep -E '^minio_cluster_(capacity_usable|usage_total)'

# 2. Tamano real de los buckets
docker exec infra-minio-1 sh -c \
  'mc alias set local http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$(cat "$MINIO_ROOT_PASSWORD_FILE")" >/dev/null && mc du local/raw-pdfs --depth 1 && mc du local/extracted-txt --depth 1'
```

Interpretacion:

- `minio_cluster_usage_total_bytes` alto y comparable a la capacidad → el
  crecimiento es de datos (paso 1).
- `minio_cluster_usage_total_bytes` ~ 0 y capacidad igualmente llena → presion
  del host (paso 2).

Referencia medida el 2026-10-31 en el stack local: capacidad usada 89.80 por
ciento (10.20 GB libres de 100.06 GB) con `usage_total_bytes = 0`, es decir todo
el consumo es del host.

> `mc alias set` dentro del contenedor escribe la config en el HOME del
> contenedor. Es efimero y no agrega exposicion: las credenciales root ya estan
> en `MINIO_ROOT_PASSWORD_FILE` del mismo contenedor. Nunca las pases por `argv`
> desde el host (se ven en `/proc/<pid>/cmdline`).

## 1. El crecimiento es de datos

1. Confirma que la retencion sigue activa en ambos buckets (verificado el
   2026-10-31: `raw-pdfs` 7 dias, `extracted-txt` 30 dias, ambas `Enabled`):

   ```bash
   docker exec infra-minio-1 mc ilm rule ls local/raw-pdfs
   docker exec infra-minio-1 mc ilm rule ls local/extracted-txt
   ```

2. Busca huerfanos: objetos subidos a `raw-pdfs` cuyo documento nunca llego a
   estado terminal (el reconciliador los purga; si hay backlog, el disco crece
   mas rapido que la retencion).
3. Si el volumen de negocio crecio y la retencion no se puede acortar, amplia el
   volumen (paso 3). No borres objetos a mano sin antes confirmar con el
   reconciliador que no hay documentos en vuelo: borrar un `raw-pdfs` que un
   worker todavia va a leer deja el documento en fallo permanente.

## 2. La presion es del host

```bash
df -h /
docker system df
docker image prune -f          # imagenes huerfanas
docker builder prune -f        # build cache
```

Si el uso sigue por encima de 85 por ciento despues de limpiar, trata el disco
del host como incidente: MinIO sin espacio rechaza escrituras y el pipeline se
detiene sin recuperacion automatica (el `POST` presignado de `doc-service`
devuelve error y el documento queda en `UPLOAD_FAILED`).

## 3. Ampliar el volumen (85 por ciento o mas)

1. Avisa: el stack queda sin MinIO durante el cambio.
2. `docker compose -f compose/docker-compose.yml --env-file .env --profile full stop minio`
3. Amplia el filesystem o el volumen `infra_minio-data` en el host.
4. `docker compose -f compose/docker-compose.yml --env-file .env --profile full start minio`
5. Verifica: `mc ls local`, `mc ilm rule ls local/raw-pdfs`, y que
   `minio_cluster_capacity_usable_total_bytes` refleje el nuevo tamano.

## 4. Respaldo de buckets (decision v1)

No se respaldan los objetos de `raw-pdfs` ni `extracted-txt`. Son artefactos
transitorios (retencion 7 y 30 dias) y regenerables; la fuente de verdad es
MongoDB, cubierta por `runbooks/restore-mongo.md`. Revisar esta decision si
aparece un requisito de retencion legal o de auditoria mayor a 30 dias.

## Tiempo de accion

La alerta sirve solo si el operador alcanza a actuar antes de que MinIO rechace escrituras. Para
cada cruce de umbral se registran cuatro marcas de tiempo, todas en UTC:

1. **Cruce del umbral:** instante en que
   `1 - usable_free / usable_total` supera 0.70 (warning) o 0.85 (critical), segun la metrica
   cruda del filesystem de MinIO.
2. **`firing` en Prometheus:** instante en que la regla pasa de `pending` a `firing` (incluye el
   `for: 5m`). Se lee de `GET /api/v1/alerts` en Prometheus.
3. **Recepcion en Alertmanager:** instante en que la alerta aparece en
   `GET /api/v2/alerts` de Alertmanager.
4. **Mitigacion del runbook:** hora de inicio y hora de fin de los pasos de este documento que
   liberan espacio o amplian el volumen.

La diferencia entre (1) y (3) es el retardo de deteccion; la diferencia entre (3) y (4) es el
tiempo humano de reaccion. **Criterio de aceptacion:** el margen entre el umbral de warning (70 %)
y el punto en que MinIO empieza a rechazar escrituras debe alcanzar para completar (4) antes de
que el disco se llene. No se registran numeros inventados: cada ensayo anota las marcas reales.

El stack aislado de `scripts/test-minio-disk-fill.sh` (tmpfs de 512 MiB, proyecto
`s5p104-minio`) mide (1)-(3) sin tocar `infra_minio-data` ni el disco del host.

## Escalamiento

| Situacion | Accion |
| --- | --- |
| warning > 70 por ciento | purgar huerfanos y confirmar lifecycle en la proxima ventana |
| critical > 85 por ciento | actuar en el momento: limpiar host o ampliar volumen |
| escrituras rechazadas / `UPLOAD_FAILED` en masa | incidente: ampliar volumen y reprocesar los documentos fallidos |
