# Runbook: documentos no terminales y reconciliador

Aplica a `DocsStuck` y `DocsAccumulating`. `PENDING_UPLOAD` se excluye de la métrica de estados intermedios: su tiempo depende de la ventana de subida.

## Diagnóstico

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T doc-service \
  wget -qO- http://localhost:8080/metrics | grep -E 'docservice_documents_(non_terminal|oldest_intermediate_age_seconds)'
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml logs --since 15m doc-service
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml ps doc-service mongo minio redis-streams
```

Consulta la versión desplegada del reconciliador y ejecútalo únicamente en modo diagnóstico/dry-run, si esa opción existe en esa versión. Revisa `UPLOADED`/`PROCESSING` antiguos y confirma existencia de objetos con `HEAD`; para `PENDING_UPLOAD` vencidos, la decisión también requiere `HEAD`.

## Recuperación segura

No borres objetos ni fuerces transiciones manuales. Determina si faltan dependencias, eventos perdidos, mensajes de Redis o trabajo del reconciliador. Antes de ejecutar reparación, conserva evidencia del dry-run, verifica idempotencia y obtiene aprobación operativa.

## Cierre

Registra estados/edades agregados, resultado de diagnóstico, dependencia afectada y convergencia observada. No incluyas IDs ni datos personales.
