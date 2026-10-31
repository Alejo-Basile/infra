# Runbook: Escalado manual del extraction-worker

Escalar el worker es un `docker compose up -d --scale`, pero **cuándo** y **cuánto** no se
improvisa: la cola es la señal, la CPU no. Este runbook implementa la decisión de
[ADR-0019](../docs/adr/ADR-0019.md) (en Compose no hay HPA ni autoscaling).

## Cuándo usarlo

- `QueueDepthHigh` en `firing`: `stream:pdf-processing` con más de 500 mensajes por 5 minutos.
- `QueueNotAdvancing` en `firing`: profundidad constante mayor a 0, con workers sanos y sin
  `DLQNotEmpty`.
- Ráfaga conocida por negocio (campaña, carga masiva) en la que se decide escalar antes de que la
  alerta dispare.

**No aplica** cuando la causa no es falta de consumidores. Ver la tabla de señales.

## Prerrequisitos

- Acceso al host con el stack `infra` desplegado y `.env` en la raíz del repo `infra/`.
- El servicio `extraction-worker` **desplegado**. Hoy todavía no existe en
  `compose/docker-compose.yml` (llega con S5-P4-01); comprobarlo antes de empezar:

  ```bash
  docker compose -f compose/docker-compose.yml --env-file .env --profile full \
    config --services | grep -x extraction-worker
  ```

  Si no imprime nada, este runbook no aplica: las alertas de cola se atienden revisando
  consumidores y la DLQ a mano hasta que el worker exista.
- El servicio no debe declarar `container_name` fijo ni publicar puertos al host: en ambos casos
  `--scale` falla o choca. Los nombres reales son `infra-extraction-worker-<n>`.

## Señales y decisión

| Alerta | Qué es | Acción |
|---|---|---|
| `QueueDepthHigh` | Entran documentos más rápido de lo que se procesan | **Escalar** (§Procedimiento) |
| `QueueNotAdvancing` | Hay trabajo y no avanza | Verificar consumidores; si están sanos, **escalar**. Si no hay ninguno, reiniciar el consumidor antes de escalar |
| `PELBacklog` | Mensajes reclamados sin `XACK` | **No escalar**: hay workers caídos o colgados. Revisar logs y `XPENDING`; `XAUTOCLAIM` los reasigna cuando vence el idle |
| `DLQNotEmpty` | Fallos definitivos | **No escalar**: diagnosticar la causa raíz (`XRANGE` de la DLQ) y corregir antes de reintentar |
| CPU alta en Redis o MinIO | Cuello de botella fuera del worker | **No escalar**: más consumidores empeoran el problema |

Regla de oro: si el número de mensajes **no crece** y no se drena, no es un problema de capacidad.

## Procedimiento

### 1. Medir la cola (y dejar la medición en la evidencia)

Helper para no repetir la password en `argv` en cada comando:

```bash
# desde la raíz del repo infra (donde vive .env)
set -a && source .env && set +a
export REDISCLI_AUTH="$(cat secrets/redis_streams_password.txt)"
rd() { docker compose -f compose/docker-compose.yml --env-file .env exec -T -e REDISCLI_AUTH redis-streams redis-cli "$@"; }
```

```bash
rd XLEN stream:pdf-processing                      # profundidad de la cola principal
rd XLEN stream:pdf-processing-dlq                  # fallos definitivos (debe ser 0)
rd XPENDING stream:pdf-processing extraction-workers   # resumen del PEL
rd XINFO GROUPS stream:pdf-processing              # consumidores registrados y lag
```

Anotar los cuatro valores con timestamp. Son la línea base del antes.

### 2. Calcular N

```text
N = ceil(XLEN / 500), acotado a 4 réplicas por host en la v1
```

- Si la alerta es `QueueNotAdvancing` con cola chica pero quieta, sumar **una** réplica.
- El tope de 4 es provisional hasta que S5-P1-01 mida el consumo real por extracción; si el host
  tiene menos núcleos que `N`, el límite real es la cantidad de núcleos.
- Nunca escalar por encima de lo que la RAM del host permite: cada réplica corre con los límites
  de `mem_limit` definidos en el compose.

### 3. Escalar

```bash
docker compose -f compose/docker-compose.yml --env-file .env --profile full \
  up -d --scale extraction-worker="$N"
```

`N` es el **total** de réplicas, no las que se agregan.

### 4. Verificar que los consumidores nuevos entraron

```bash
docker compose -f compose/docker-compose.yml --env-file .env ps extraction-worker
rd XINFO GROUPS stream:pdf-processing    # "consumers" debe reflejar N
rd XLEN stream:pdf-processing            # debe empezar a bajar
rd XPENDING stream:pdf-processing extraction-workers
```

Los workers nuevos se registran en el consumer group `extraction-workers` al primer
`XREADGROUP`; un consumidor registrado sin mensajes asignados todavía es normal.

### 5. Confirmar el objetivo

La profundidad de la cola debe **bajar al menos a la mitad en menos de 10 minutos** desde el
escalado. Si no baja:

- `XINFO GROUPS` muestra los consumidores pero `XLEN` no baja → el worker no está completando
  trabajos: mirar logs y `XPENDING`, no escalar más.
- `consumers` no aumentó → el servicio no arrancó (revisar `ps`, logs y límites de memoria).
- La cola drena pero el PEL crece → `WORKER_AUTOCLAIM_IDLE_MS` mal calibrado frente al timeout
  duro (SPEC §5.4); se corrige en configuración, no con réplicas.

## Rollback

Cuando la cola volvió a la normalidad:

```bash
docker compose -f compose/docker-compose.yml --env-file .env --profile full \
  up -d --scale extraction-worker=1
```

- Un consumidor eliminado puede dejar entradas en el PEL; `XAUTOCLAIM` las reasigna cuando vence
  `min-idle-time`, que debe ser `≥ 2 × WORKER_JOB_TIMEOUT_SEC`. Un `PELBacklog` transitorio
  después de bajar réplicas es esperado, no una alerta para volver a escalar.
- Si el escalado degradó el pipeline (Redis saturado, errores en cadena), volver a `1` y tratar el
  incidente como problema de capacidad del backend, no del worker.

## Notas importantes

- **La CPU no es el criterio.** La extracción es de un solo núcleo y dominada por I/O: la CPU se
  entera tarde de la ráfaga.
- **No hay autoscaling.** Compose no tiene HPA; esto es manual por diseño (ADR-0019). El
  autoscaling real queda para una ADR futura si el proyecto migra a Kubernetes (KEDA).
- **Escalar no arregla datos.** `DLQNotEmpty` y `PELBacklog` son fallos, no falta de capacidad.
- **Este runbook no reemplaza el de Redis.** Si la alarma real es un failover de Sentinel, el
  procedimiento es otro (hoy sin runbook propio: deuda registrada en ADR-0019).

## Evidencia

Cada ejecución deja un registro en `docs/evidencias/S5/S5-P1-02-escalado.txt` con: valores de
`XLEN`/`XPENDING` antes y después, `N` aplicado, timestamp del escalado y minuto en que la
profundidad se redujo a la mitad. Sin credenciales ni valores de secretos en el archivo.

> Estado: **pendiente**. El ensayo con una ráfaga de 500 documentos requiere el worker desplegado
> (S5-P4-01) y sus límites calibrados (S5-P1-01).
