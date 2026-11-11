# Runbook: errores de extracción y DLQ

Aplica a `ExtractionErrors` y `DLQNotEmpty`. La alerta identifica fallos o rechazos; no significa que todos los PDFs necesiten reintento.

## Diagnóstico

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T redis-streams \
  sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli XLEN stream:pdf-processing-dlq'
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T extraction-worker \
  curl -fsS http://localhost:8081/metrics | grep -E '^worker_(documents|dlq)_total'
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml logs --since 15m extraction-worker
```

Inspecciona los IDs y causas de DLQ con `XRANGE stream:pdf-processing-dlq - + COUNT 20`, usando el mismo contenedor Redis y autenticación por `REDISCLI_AUTH`.

## Decisión

- `REJECTED` / `NOT_A_PDF` es terminal y no se reintenta; revisa el origen y el corpus.
- `EXTRACTION_FAILED` corresponde a PDFs válidos sin extracción satisfactoria tras reintentos; agrupa por causa y reproduce solo una muestra controlada.
- No borres la DLQ ni hagas replay masivo antes de confirmar causa, idempotencia y capacidad del worker.

## Cierre

Registra el volumen antes/después, causas inspeccionadas y resultado del replay en la evidencia de staging. No incluyas documentos ni datos personales en el registro.
