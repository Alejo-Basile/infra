# Runbook: failover de Redis Sentinel (Streams)

Alertas que enlazan acá (`runbook_url` en `compose/prometheus/alert.rules.yml`):
`QueueDepthHigh`, `PELBacklog`, `DLQNotEmpty`, `RedisMemHigh`, `LatencyP95High`.

Aviso honesto: no todas esas alertas significan "hubo un failover". `RedisMemHigh` y
`LatencyP95High` son síntomas que pueden tener causas ajenas a Sentinel; en esos casos
el failover es el último paso, no el primero. `QueueDepthHigh`, `PELBacklog` y
`DLQNotEmpty` apuntan al pipeline detenido o acumulado: ahí sí revisá Sentinel primero.

## Topología desplegada (verificada 2026-10-31)

| Elemento | Valor |
| --- | --- |
| Maestro monitoreado | `myprimary` → `redis-streams:6379` |
| Sentinels | `sentinel-1`, `sentinel-2`, `sentinel-3` (puerto 26379) |
| Quorum | 2 |
| Autenticación de Sentinel | sin `requirepass` (no uses `REDISCLI_AUTH` contra 26379) |
| Autenticación de Redis | `requirepass`; el secreto está en `/run/secrets/redis_streams_password` |
| Clientes | `doc-service` (Go, dos réplicas) en modo Sentinel. El worker Rust todavía no está desplegado |

Nunca escribas la contraseña en `argv` (se ve en `/proc/<pid>/cmdline`). Pasá solo el
nombre de la variable: `docker compose exec -e REDISCLI_AUTH ...`, con `REDISCLI_AUTH`
exportado en tu shell; o leé el archivo dentro del contenedor como en los comandos de abajo.

Todos los comandos asumen que estás en la raíz del repo `infra`:

```bash
cd infra
C="docker compose -f compose/docker-compose.yml --env-file .env"
$C --profile full ps
```

Sin `--profile full` (o `sentinel`) y sin `--env-file .env`, Compose no ve los servicios.

## 1. Diagnóstico: quién es el maestro y si hay quorum

```bash
for s in 1 2 3; do
  printf 'sentinel-%s: ' "$s"
  $C exec -T "sentinel-$s" redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | tr '\n' ' '
  echo
done

$C exec -T sentinel-1 redis-cli -p 26379 SENTINEL master myprimary | paste - - | grep -E 'num-slaves|num-other-sentinels|quorum|^(name|ip|port)'
```

Lectura de los resultados:

- Los tres sentinels deben responder el **mismo** par `host puerto`. Si no coinciden,
  están en medio de un failover: esperá unos segundos y volvé a consultar.
- `quorum 2` con `num-other-sentinels 2` significa que hay 2 sentinels de 3 vivos y
  pueden decidir. Si `num-other-sentinels` baja de 1, no hay failover automático posible.
- Si el maestro reportado no responde, seguí con el paso 2.

Rol real de cada nodo (la verdad del servidor, no la opinión de Sentinel):

```bash
for n in redis-streams redis-streams-replica-1 redis-streams-replica-2; do
  printf '%s: ' "$n"
  $C exec -T "$n" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli INFO replication'
done | grep -E '^(role|master_link_status|connected_slaves)'
```

## 2. Failover planificado (mantenimiento, sin perder el maestro)

```bash
$C exec -T sentinel-1 redis-cli -p 26379 SENTINEL FAILOVER myprimary
```

Sentinel promueve una réplica y demota al maestro. Medido en este stack:
**consenso de los tres sentinels en 2 segundos** (ver evidencia S6-P1-01).

Verificación inmediata (repetir hasta que los tres coincidan):

```bash
for s in 1 2 3; do
  $C exec -T "sentinel-$s" redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -1
done | sort -u
```

## 3. Failover de emergencia (el maestro está caído)

```bash
$C --profile full stop redis-streams
```

Los sentinels detectan la caída (`down-after-milliseconds`) y promueven una réplica.
Después del failover **no vuelvas a levantar el nodo viejo esperando que siga siendo
maestro**: al arrancar entra como réplica del maestro nuevo. Si querés devolver la
topología original, usá el rollback del paso 6.

## 4. Verificación del pipeline

```bash
NEW=$($C exec -T sentinel-1 redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -1)

# Profundidad de la cola en el maestro nuevo.
$C exec -T "$NEW" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli XLEN stream:pdf-processing'

# Pendientes del consumer group (mensajes entregados y nunca confirmados).
$C exec -T "$NEW" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli XPENDING stream:pdf-processing extraction-workers'
```

Qué mirar:

- `XLEN` **no** tiene que dar el mismo número que antes: la replicación es asíncrona y
  los `XADD` no replicados se pierden con el maestro viejo. Se pierden mensajes, **no
  documentos**: el reconciliador del Document Service los reencola desde Mongo (§6.5 del
  SPEC). La garantía es la convergencia a estado terminal, no "cero pérdida".
- `XPENDING` con entradas viejas significa que hay trabajos reclamados por un worker
  que murió: los recupera `XAUTOCLAIM`, no este runbook.

Prueba de que el cliente sigue **escribiendo** en el maestro nuevo (la que distingue un
cliente Sentinel-aware de uno de dirección fija):

```bash
# 1) Ninguna conexión del cliente debe quedar en el nodo demotado.
$C exec -T redis-streams sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli CLIENT LIST' | grep -c '172\.22\.0\.'

# 2) Toda escritura debe caer en el maestro nuevo.
$C exec -T "$NEW" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli XLEN stream:pdf-processing'
```

Si una escritura contra la dirección fija del cliente devuelve
`READONLY You can't write against a read only replica`, ese cliente **no** está en modo
Sentinel. Ese fue el caso de `doc-service` hasta S6-P1-01: el binario ya soportaba
`FailoverClient`, pero el compose le pasaba `REDIS_ADDR` fija. Hoy usa
`REDIS_SENTINEL_ADDRS` + `REDIS_MASTER_NAME`.

## 5. Logs a mirar

```bash
docker logs --since 10m infra-doc-service-1 2>&1 | grep -iE 'redis|readonly|failover|reconnect'
```

Ojo: `/readyz` de `doc-service` responde 200 aunque Redis esté caído (solo verifica que
el proceso vive, `internal/transport/http/health.go:27`). Un `/readyz` verde **no** prueba
que el cliente pueda escribir. Por eso la verificación del paso 4 no es opcional.

## 6. Rollback (volver al maestro original)

Sentinel no permite elegir el próximo maestro: promueve la réplica que considera mejor.
Para volver a `redis-streams`, repetí el failover hasta que lo promueva (en la práctica,
uno o dos intentos):

```bash
for intento in 1 2 3; do
  cur=$($C exec -T sentinel-1 redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary | head -1)
  [ "$cur" = "redis-streams" ] && { echo "maestro: $cur"; break; }
  $C exec -T sentinel-1 redis-cli -p 26379 SENTINEL FAILOVER myprimary
  sleep 8
done
```

Verificá que el nodo demotado terminó la resincronización (tarda unos segundos más que
el failover):

```bash
for n in redis-streams-replica-1 redis-streams-replica-2; do
  printf '%s: ' "$n"
  $C exec -T "$n" sh -c 'REDISCLI_AUTH=$(cat /run/secrets/redis_streams_password) redis-cli INFO replication' | grep -E '^(role|master_link_status)' | tr '\n' ' '
  echo
done
```

Estado sano: `redis-streams` con `role:master` y `connected_slaves:2`; las dos réplicas con
`role:slave` y `master_link_status:up`. Medido: la resincronización completa quedó en
`up` unos 12 segundos después del failover.

## 7. Escalamiento

| Síntoma | Acción |
| --- | --- |
| Los tres sentinels dan maestros distintos por más de 30 s | Revisar `docker logs` de los sentinels; verificar que se ven entre sí en la red `data` |
| `num-other-sentinels` menor a 1 | Quórum perdido: no habrá failover automático. Restaurar el sentinel caído antes que nada |
| Un nodo reporta `role:master` y el maestro real no lo reconoce | Posible split brain transitorio durante la resincronización: esperar y confirmar con `INFO replication` en los tres antes de intervenir |
| Escrituras con `READONLY` después del failover | El cliente no es Sentinel-aware: revisar `REDIS_SENTINEL_ADDRS` y `REDIS_MASTER_NAME` en su servicio |
| Cola que no baja después del failover | No es un problema de Sentinel: revisar si hay workers vivos y consumiendo (ver el runbook de escalado del worker, S5-P1-02 / ADR-0019) |

## 8. Estado del ensayo (2026-10-31)

Ejecutado de punta a punta en el stack local, con mediciones reales en
`docs/evidencias/S6/S6-P1-01-failover-redis.txt`:

- Failover planificado: consenso en **2 s**, maestro promovido `redis-streams-replica-1`.
- `XLEN` antes 77, después 77 (sin pérdida en este ensayo).
- Defecto encontrado y corregido: `doc-service` escribía contra una réplica
  (`READONLY`) porque el compose no le pasaba los sentinels.
- Con el fix: escritura de punta a punta verificada contra el maestro nuevo
  (`XLEN` 77 → 78 con el mensaje del relay).
- Rollback ensayado: maestro de vuelta en `redis-streams`, 2 réplicas `up`, `XLEN` 77.

No verificado: el cliente **Rust** (worker), porque no está desplegado. Mientras eso
siga así, el criterio (b) de S6-P1-01 queda incompleto y no debe declararse cumplido.
