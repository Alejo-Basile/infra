# Runbook: Tráfico del gateway (rate limiting)

## Alcance
Alertas: `HighErrorRate`, `TraefikRateLimited`, `LatencyP95High`, `RateLimitDegraded`, `RateLimitDaemonDown`.

## Contrato de rate limiting desplegado
- ForwardAuth: `http://ratelimitd:8090/check?key=api-v2&rate=10&burst=20`
- Redis key: `rl:{scope}:{identity}`; identity = IP del cliente derivada del `X-Forwarded-For` más a la derecha / `RemoteAddr`.
- Exentos: `/internal`, `/healthz`, `/metrics`.
- 429 lleva `Retry-After` + `X-RateLimit-Retry-After` + `X-RateLimit-Remaining`.
- Los headers 2xx llegan al cliente solo porque `doc-service` los repite: Traefik reenvía `authResponseHeaders` a la request del backend, no a la respuesta del cliente. Caveat de despliegue local: la imagen en ejecución es `doc-service:local`, construida desde `doc-service-worktrees/s7-p1-05-echo` vía `compose/docker-compose.build.yml` + `DOC_SERVICE_BUILD_CONTEXT`; un `up -d` sin ese override revierte a la imagen GHCR y rompe los headers en el camino 200.

## Diagnóstico RateLimitDegraded
Comandos:
- `docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full ps redis-ratelimit ratelimitd`
- `docker compose ... logs --tail=50 ratelimitd`
- `docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full exec -T redis-ratelimit sh -c 'REDISCLI_AUTH="$(cat /run/secrets/redis_ratelimit_password)" redis-cli --no-auth-warning PING'` (esperado: `PONG`)
- `curl -sk -D - -o /dev/null -H 'Host: api.localhost' https://127.0.0.1:8543/api/v2/documents` (durante fail-open: `200` + `x-ratelimit-degraded: true`)
- `docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full exec -T ratelimitd wget -qO- http://127.0.0.1:8090/metrics` (expone `ratelimit_requests_total{decision}` y `ratelimit_redis_up`)

Resultados:
- Redis sano/transitorio: reconexión automática, sin acción.
- Redis caído: `docker compose ... start redis-ratelimit`.
- ratelimitd caído: gateway 5xx; revisar logs/secreto.

## RateLimitDaemonDown
El fail-open solo cubre la caída de Redis. Si ratelimitd está caído, el ForwardAuth de `/api/v2` falla y el gateway devuelve 5xx.
Checklist de recuperación: verificar contenedor, logs, secreto, reiniciar solo ratelimitd.

## TraefikRateLimited masivos / 429 legítimos
Distinguir agotamiento de bucket de degradación. Knobs globales: rate/burst en el middleware file.

## Garantías de recuperación
Reconexión automática; no se requiere reinicio de Traefik ni ratelimitd ante un rebote de Redis.

## Fail-closed NO habilitado
Contrario a fail-closed por ruta es flag de P4; habilitarlo convertiría una caída de Redis en 503.

## Fallback de emergencia
El `RateLimit` nativo de Traefik es por instancia (memoria), solo usable con una sola réplica de Traefik; nunca equivalente al ForwardAuth.

## Procedimiento de drill (fail-open verificado)

```bash
# 1. Detener SOLO el Redis de rate limit
docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full stop redis-ratelimit
# 2. Generar tráfico y observar el header de degradación (200, sin 5xx)
curl -sk -D - -o /dev/null -H 'Host: api.localhost' https://127.0.0.1:8543/api/v2/documents
# 3. Confirmar la alerta (tarda ~1-2 min: for: 1m sobre increase[2m])
docker exec infra-prometheus-1 wget -qO- http://127.0.0.1:9090/api/v1/alerts | grep RateLimitDegraded
# 4. Restaurar y confirmar recuperación automática
docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full start redis-ratelimit
```

Registro de la última corrida: `docs/evidencias/S7/S7-P1-05-failopen.txt` y
`docs/evidencias/S7/S7-P1-05-alerta.txt`.
