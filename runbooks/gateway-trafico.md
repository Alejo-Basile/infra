# Runbook: tasas 5xx y 429 de Traefik

Aplica a `HighErrorRate`, `TraefikRateLimited` y `LatencyP95High`.

## Separar las señales

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml logs --since 15m traefik
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml ps doc-service monolito
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T doc-service \
  wget -qO- http://localhost:8080/healthz
```

- **5xx**: inspecciona backend objetivo, healthcheck, logs y cambios recientes. Si coincide con un despliegue y el backend no se recupera, aplica el rollback aprobado.
- **429**: confirma middleware/ForwardAuth y límites configurados; un 429 es rechazo intencional, no indisponibilidad del backend. No eleves límites sin validar Redis y política de abuso.
- **p95**: correlaciona latencia de Traefik con Mongo, Redis y MinIO antes de escalar cualquier servicio.

## Cierre

Registra códigos/servicio, backend comprobado, cambio aplicado y comprobación posterior. Evita guardar cabeceras de autenticación o datos de clientes.
