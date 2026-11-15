# Runbook: tasas 5xx y 429 de Traefik, y degradacion de rate limiting

Aplica a `HighErrorRate`, `TraefikRateLimited`, `LatencyP95High`, `RateLimitDegraded` y
`RateLimitdDown`.

## Rate limiting degradado (fail-open)

Senal: respuestas 200 con `X-RateLimit-Degraded: true`, o alerta `RateLimitDegraded`. No hay 429 ni
5xx: el limite dejo de aplicarse y la API sigue respondiendo.

```bash
docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full \
  ps redis-ratelimit ratelimitd
docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full \
  logs --since 15m redis-ratelimit ratelimitd
docker compose -f infra/compose/docker-compose.yml --env-file infra/.env --profile full \
  exec -T redis-ratelimit sh -c \
  'REDISCLI_AUTH="$(cat /run/secrets/redis_ratelimit_password)" redis-cli --no-auth-warning PING'
```

- `PING` responde: Redis esta sano y la degradacion es transitoria; confirmar con un request al
  gateway que ya no aparece el header.
- `PING` falla o el contenedor esta detenido: restaurar con
  `docker compose ... --profile full start redis-ratelimit`. **No** reiniciar Traefik ni
  `ratelimitd`: reconectan solos.
- `ratelimitd` caido (no `redis-ratelimit`): es otra falla. El gateway falla en `/api/v2`; revisar
  logs del contenedor y el secreto. No se resuelve reiniciando Redis.

### Propagacion del header de fail-open (backend echo)

Traefik forwardAuth, ante una respuesta 2xx del auth server, copia los headers de
`authResponseHeaders` sobre el request reenviado al backend, no sobre la respuesta
al cliente. Por eso doc-service ecoa la whitelist de rate-limit headers desde el
request hacia la respuesta. Los nombres deben permanecer en `authResponseHeaders`
de `infra/traefik/dynamic/middlewares.yml` para cerrar el spoofing (Traefik los
elimina del request del cliente antes de reenviar).

Sintoma cuando se rompe: `/check` directo tiene `X-RateLimit-Degraded`, pero el
gateway no. Revisar middleware de echo en doc-service y version de imagen.

Ventana de riesgo: mientras dure la degradacion no hay limite efectivo. Si el trafico es anomalo,
aplicar contencion en el borde (bloqueo temporal por IP en el proxy o firewall) y registrar la
decision; el fallback nativo `RateLimit` de Traefik OSS cuenta por instancia y solo sirve como
emergencia con una sola instancia de Traefik.

## Pendiente P4

`ratelimitd` solo expone `/healthz` y `/check`; no hay `/metrics` ni contador
`ratelimit_degraded_total`, ni job de scrape en `prometheus.yml`. Por eso `RateLimitDegraded` y
`RateLimitdDown` no estan en `alert.rules.yml` hasta que P4 exponga metricas.
