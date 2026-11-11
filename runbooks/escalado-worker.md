# Runbook: Escalado manual del extraction-worker

Escalar el worker es un `docker compose up -d --scale`, pero **cuándo** y **cuánto** no se
improvisa: la cola es la señal, la CPU no. Este runbook implementa la decisión de
[ADR-0019](../docs/adr/ADR-0019.md) (en Compose no hay HPA ni autoscaling).

## Cuándo usarlo

- `QueueDepthHigh` en `firing`: `docservice_documents_non_terminal > 500` (documentos no
  terminales operativos) durante 5 minutos.
- `QueueNotAdvancing` en `firing`: profundidad constante mayor a 0, con workers sanos y sin
  `DLQNotEmpty`.
- Ráfaga conocida por negocio (campaña, carga masiva) en la que se decide escalar antes de que la
  alerta dispare.

**No aplica** cuando la causa no es falta de consumidores. Ver la tabla de señales.

## Prerrequisitos

- Acceso al host con el stack `infra` desplegado y `.env` en la raíz del repo `infra/`.
- El servicio `extraction-worker` desplegado (S5-P4-01). Comprobarlo antes de empezar:

  ```bash
  docker compose -f compose/docker-compose.yml --env-file .env --profile full \
    config --services | grep -x extraction-worker
  ```

  La imagen se publica como `ghcr.io/<org>/extraction-worker`; en local se puede fijar
  `EXTRACTION_WORKER_IMAGE`/`EXTRACTION_WORKER_TAG` para usar una build propia.
- El servicio no debe declarar `container_name` fijo ni publicar puertos al host: en ambos casos
  `--scale` falla o choca. Los nombres reales son `infra-extraction-worker-<n>`.

## Señales y decisión

| Alerta | Qué es | Acción |
|---|---|---|
| `QueueDepthHigh` | Más de 500 documentos no terminales operativos (`docservice_documents_non_terminal`) durante 5m | **Escalar** (§Procedimiento) |
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
rd XLEN stream:pdf-processing-dlq                  # fallos definitivos (debe ser 0)
rd XPENDING stream:pdf-processing extraction-workers   # resumen del PEL
rd XINFO GROUPS stream:pdf-processing              # consumidores registrados y lag
```

**La profundidad que importa es `docservice_documents_non_terminal`**, no `XLEN` ni `lag`:

- Es el número de documentos en estados no terminales operativos (UPLOADED, QUEUED,
  PROCESSING, RETRYING, EXTRACTION_FAILED, COMPENSATING). Excluye `PENDING_UPLOAD` y los
  terminales, y converge a 0 cuando todo termina. Es la señal que evalúa `QueueDepthHigh`.
- `XLEN` no baja nunca al consumir: las entradas quedan hasta `XDEL`/`XTRIM`.
- `lag`/`entries-read` pueden quedar estancados tras un recorte o un failover: la resta
  `entries_added_total - entries_read` deja una diferencia fantasma permanente. No se usan
  para decidir el escalado.
- `PEL` y `XLEN` siguen siendo útiles para diagnosticar (mensajes trabados, DLQ), no para
  medir la profundidad de la cola.

```bash
# profundidad real: gauge de doc-service vía Prometheus
docker exec infra-prometheus-1 wget -qO- \
  'http://localhost:9090/api/v1/query?query=docservice_documents_non_terminal' |
  jq -r '.data.result[0].value[1]'
```

Anotar ese valor con timestamp. Es la línea base del antes.

### 2. Calcular N

```text
N = ceil(docservice_documents_non_terminal / 500)
N = min(N, nucleos_del_host / WORKER_MAX_CONCURRENCY)   # tope por CPU
N = min(N, 4)                                            # tope provisional de la v1
```

- **El tope por CPU no es opcional en cargas CPU-bound.** Medido: con 4 núcleos y
  `WORKER_MAX_CONCURRENCY=4`, pasar de 1 a 4 workers mantuvo el throughput en ~2,2 docs/s
  (2,23 vs 2,13). Un worker ya satura la CPU; las réplicas extra solo agregan contención.
  Escalar réplicas rinde cuando el host tiene núcleos de sobra o la carga es I/O-bound.
- Si la alerta es `QueueNotAdvancing` con cola chica pero quieta, sumar **una** réplica.
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
docker compose -f compose/docker-compose.yml --env-file .env --profile full ps extraction-worker
rd XINFO GROUPS stream:pdf-processing    # "consumers" debe reflejar N
rd XPENDING stream:pdf-processing extraction-workers   # diagnóstico de mensajes trabados
# docservice_documents_non_terminal debe empezar a bajar (query de Prometheus de arriba)
```

Los workers nuevos se registran en el consumer group `extraction-workers` al primer
`XREADGROUP`; un consumidor registrado sin mensajes asignados todavía es normal.

### 5. Confirmar el objetivo

La profundidad (`docservice_documents_non_terminal`) debe **bajar al menos a la mitad en menos de
10 minutos** desde el escalado. Si no baja:

- `XINFO GROUPS` muestra los consumidores pero `docservice_documents_non_terminal` no baja → el
  worker no está completando trabajos: mirar logs y `XPENDING`, no escalar más.
- `consumers` no aumentó → el servicio no arrancó (revisar `ps`, logs y límites de memoria).
- La cola drena pero el PEL crece → `WORKER_MIN_IDLE_MS` mal calibrado frente al timeout
  duro (SPEC §5.4); se corrige en configuración, no con réplicas.
- `docservice_documents_non_terminal` baja igual de rápido con más réplicas que con una → el
  cuello es la CPU del host: volver a `1` y escalar en otro host (H2 del ensayo de S5-P1-02).

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

Cada ejecución deja un registro en `docs/evidencias/S5/S5-P1-02-ensayo-escalado.txt` con:
`docservice_documents_non_terminal` antes y después, `N` aplicado, timestamp del escalado y minuto
en que la profundidad se redujo a la mitad. Sin credenciales ni valores de secretos en el archivo.

> Estado: **ensayado** (2026-11-04, 700 documentos, `docs/evidencias/S5/S5-P1-02-ensayo-escalado.txt`).
> La alerta disparó a los 5 min, el runbook se siguió tal cual y el backlog drenó completo. Aquel
> ensayo midió `lag + PEL`; la señal se corrigió después a `docservice_documents_non_terminal`
> porque los contadores de Redis quedaban fantasma tras recortes y failovers.
> Pendiente de seguimiento: `XTRIM`/retención del stream para que `XLEN` signifique algo.
