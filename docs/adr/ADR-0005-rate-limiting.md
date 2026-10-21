# ADR-0005 — Algoritmo de rate limiting distribuido en Redis

- **Estado:** Aceptado (decisión técnica de P4; revisión cruzada P1 pendiente de acuse)
- **Fecha:** Semana 1 (S1-P4-01), 2026-10-21
- **Owner:** P4
- **Contexto:** `SPEC.md` v2.1 §8 · `plan-P4-S0-S1.md` §5.2 · ADR-0016 · `redis-ratelimit`

## Contexto

El middleware nativo `RateLimit` de Traefik OSS mantiene el contador en memoria de cada
instancia. Con más de una réplica de Traefik, una identidad puede consumir el límite una vez por
réplica. La solución del SPEC es un servicio propio detrás de `ForwardAuth` que consulta e
incrementa un contador compartido en Redis. En S1 se decide el algoritmo y se implementa el
núcleo atómico; el servicio ForwardAuth completo es S7.

Restricciones del entorno:

- Redis 7.2 con `requirepass` en `redis-ratelimit`, separado de `redis-streams`.
- Datos efímeros: `appendonly no`, `maxmemory 96mb`, `allkeys-lru`.
- Una sola operación atómica por request, sin `INCR` seguido de `EXPIRE` desde el cliente.
- El reloj que decide es el del servidor Redis (`TIME`), no el del cliente.

## Opciones consideradas

| Criterio | Token bucket | Sliding window log | GCRA |
|---|---|---|---|
| Precisión del límite | Buena; depende del refill | Exacta dentro de la ventana | Exacta, sin ventanas discretas |
| Memoria por identidad | 2 campos (tokens, timestamp) | O(n) entradas por ventana | 1–2 campos (TAT) |
| Ráfagas | Permite hasta `capacity` | Permite hasta el límite de la ventana | Permite hasta `burst` y luego suaviza |
| Operaciones Redis | 1 `EVAL` | `ZADD` + `ZREMRANGEBYSCORE` + `ZCARD` o `EVAL` | 1 `EVAL` |
| Coste bajo ataque | Constante | Crece con el número de requests | Constante |
| Deriva / bordes de ventana | No aplica | Riesgo de doble ráfaga en el borde | No aplica |
| Complejidad de cálculo | Baja | Media | Media |
| Modo de fallo | Redis caído detiene la decisión | Redis caído detiene la decisión | Redis caído detiene la decisión |

1. **Token bucket** — descartado como elección principal. Es correcto y barato, pero el cálculo
   de tokens con decimales y el refill introducen más superficie de error que GCRA para el mismo
   resultado, y el SPEC pide un comportamiento suave con ráfagas acotadas.
2. **Sliding window log** — descartado. Es exacto, pero guarda una entrada por request; con
   muchas identidades o un ataque de ráfaga el consumo de memoria crece sin cota práctica y
   contradice el `maxmemory` de 96 MB de la instancia.
3. **GCRA (Generic Cell Rate Algorithm)** — **elegido**. Mantiene un solo `TAT` (theoretical
   arrival time) por identidad, permite una ráfaga acotada y luego impone la tasa media. Se
   implementa con un único `EVAL`, memoria O(1) y sin ventanas discretas.

## Decisión

Se implementa **GCRA** en `platform-services/rate-limiter/internal/limiter/gcra.lua`.

### Parámetros

- `rate`: peticiones por segundo sostenidas.
- `burst`: peticiones que se admiten de forma instantánea.
- `T = 1_000_000 / rate` microsegundos: intervalo de emisión.
- `τ = burst * T` microsegundos: tolerancia de ráfaga.
- `now`: `TIME` de Redis, en microsegundos.
- `TAT`: estado persistido en la clave, en microsegundos.

### Cálculo

```text
new_tat  = max(TAT, now) + T
allow_at = new_tat - τ

si now >= allow_at:
    TAT = new_tat
    allowed = 1
    remaining = floor((now + τ - new_tat) / T)
    retry_after = 0
si no:
    allowed = 0
    remaining = 0
    retry_after = ceil((allow_at - now) / 1_000_000)
```

La primera petición inicializa `TAT = now`. Con `burst = N`, `τ = N * T` deja pasar exactamente
`N` peticiones inmediatas y la siguiente queda limitada. El `retry_after` se expresa en segundos
redondeados hacia arriba y nunca es menor que 1 cuando la petición se rechaza.

### Atomicidad y expiración

- Un único `EVAL` lee `TIME`, calcula, actualiza `TAT` y fija el TTL.
- El TTL de la clave es `ceil((new_tat - now) / 1_000_000) + 1` segundos. La clave desaparece
  cuando el estado ya no puede afectar a ninguna decisión futura.
- Prohibido `INCR` + `EXPIRE` desde el cliente: deja una ventana en la que el contador puede
  quedar sin expiración o perder una actualización.
- La clave se nombra `rl:{scope}:{identity}`; `scope` separa rutas o límites y `identity` es la
  clave de cliente que decida S7 (IP, API key o usuario).

### Fallo de Redis

Decisión para S1: **fail-open controlado**. Si `redis-ratelimit` no responde, el wrapper devuelve
`200` con `X-RateLimit-Degraded: true` y emite una métrica de error. Se prefiere degradar la
protección antes que tumbar la API completa. El modo fail-closed queda como opción de
configuración para S7, cuando exista una política de negocio que lo justifique.

## Consecuencias

- **Positivas:** memoria constante por identidad, una sola llamada atómica, sin deriva de
  ventanas, fácil de razonar y de probar; el estado expira solo.
- **Negativas:** el cálculo es menos intuitivo que un contador; un error en `τ` cambia el tamaño
  de la ráfaga. Se mitiga con tests unitarios de los bordes y con la prueba de 100 clientes.
- **Operativas:** Redis se convierte en dependencia del camino de admisión. La separación de
  instancias y el fail-open acotan el impacto; la observabilidad de S7 debe alertar sobre
  `X-RateLimit-Degraded`.
- **Alcance:** esta ADR no implementa ForwardAuth, identidad de cliente, configuración por ruta
  ni distribución entre réplicas de Traefik. Eso es S7.

## Verificación

1. Tests unitarios del cálculo para `burst = 1`, ráfaga exacta, rechazo y expiración.
2. `redis-cli --eval` contra `redis-ratelimit` real: el script devuelve `allowed`, `remaining` y
   `retry_after` coherentes.
3. k6 con 100 clientes concurrentes sobre la misma clave: ninguno supera `rate`/`burst`.
4. Tras el TTL no quedan claves `rl:*` de prueba.
5. El código no usa `INCR` ni `EXPIRE` desde el cliente.
