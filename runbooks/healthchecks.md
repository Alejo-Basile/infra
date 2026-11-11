# Runbook: readiness y dependencias

Aplica a `DocServiceNotReady` y `WorkerNotReady`, además de los endpoints de salud de observabilidad. Los checks de Prometheus prueban disponibilidad del endpoint scrapeado; no sustituyen una verificación de dependencias.

## Diagnóstico

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml ps
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml logs --since 10m doc-service extraction-worker mongo minio redis-streams
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T extraction-worker curl -i http://localhost:8081/readyz
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T doc-service wget -S -qO- http://localhost:8080/readyz
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T prometheus wget -qO- http://localhost:9090/-/healthy
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T loki /usr/local/bin/wget -qO- http://localhost:3100/ready
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T grafana wget -qO- http://localhost:3000/api/health
```

Comprueba Mongo, MinIO y Redis por separado con sus healthchecks y herramientas autenticadas. Los healthchecks de `doc-service` y `extraction-worker` consultan `/readyz`, que debe reflejar la conectividad requerida a Mongo, MinIO y Redis, no solo que el proceso HTTP responde. `/healthz` solo acredita liveness.

Prometheus, Loki y Grafana usan sus endpoints nativos (`/-/healthy`, `/ready` y `/api/health`). La imagen upstream de redis-exporter no contiene shell, `wget` ni `curl` (`docker exec ... wget` devuelve “executable file not found”); no se inventó un proceso-check. Excepción de healthcheck: Prometheus monitoriza el target `/metrics` y alerta si `up{job="redis-exporter"}` baja a 0. El job se mantiene RO, no-root y con límites.

## Recuperación

Restaura primero la dependencia fallida y confirma recuperación del check. Reinicia un servicio solo tras revisar logs/configuración; evita reinicios simultáneos que oculten la causa.

## Cierre

Registra servicio, dependencia, transición del healthcheck y resultado. No guardes credenciales ni salida con información sensible.
