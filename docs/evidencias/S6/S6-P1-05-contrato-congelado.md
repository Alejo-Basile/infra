# S6-P1-05 — Contrato de mensajes congelado (`schema_version=1`) y preparación de la puerta G3

Este documento es el artefacto de evidencia de `S6-P1-05`. NO es el plan de ejecución
(`docs/S6/tasks/task-5.md` se declara explícitamente no normativo) y NO declara la puerta G3:
la revisión de arquitectura es quien decide Go o No-Go (`docs/pasos-iniciales.md:239-240`).

Todo se verificó leyendo el código real de los commits declarados, sin ejecutar
`docker`/`redis-cli` ni mutar estado. Los hashes SHA-256 se recalcularon sobre los archivos
commiteados. Fecha de verificación (UTC): 2026-11-15.

## Identidad de la corrida

| Campo | Valor |
|---|---|
| Fecha de verificación (UTC) | 2026-11-15 |
| Productor — repo | `doc-service` |
| Productor — rama | `feat/s6-p1-02-reconciler-txt-bucket-crosscheck` |
| Productor — HEAD | `f67c266aa98f779b890bfb1c659a46bc2e2c3d36` |
| Productor — HEAD (asunto / fecha) | `feat(reconciler): validate txt in extracted-txt bucket and expose cross-check` · 2026-11-14 18:55:08 -0300 |
| Productor — árbol de trabajo | `git -C doc-service status --short` → vacío (limpio) |
| Consumidor — repo | `extraction-worker` |
| Consumidor — rama | `main` |
| Consumidor — HEAD | `d39dde42e58a9b19e341c7f39ce8ec3185dc83b6` |
| Consumidor — HEAD (asunto / fecha) | `test(labs): añadir arnés reproducible de carga hostil (S5-P1-01)` · 2026-11-14 18:10:20 -0300 |
| Consumidor — árbol de trabajo | `git -C extraction-worker status --short` → vacío (limpio) |
| Autor del artefacto | P1 (transcribe lo observado; no firma la validez del contrato) |

SHA-256 de los cuatro archivos que fijan el contrato, calculados sobre los commits anteriores:

| Archivo | SHA-256 |
|---|---|
| `doc-service/internal/adapters/redis/queue.go` | `682bf9ae9874e33043204d7926d80b0441d956f3f884689a2456c5f425738080` |
| `doc-service/internal/adapters/relay/relay.go` | `9bfb52bf8a8584479fb36bf22175555e59e3fac70ddaa650c5ea0e2d38a298be` |
| `extraction-worker/crates/core/src/lib.rs` | `1a3edf8a4856480f334ab013fd115357aff6f928d37c0c2bac36a669dbc69746` |
| `extraction-worker/crates/worker/src/consumer/dlq.rs` | `601f51627f09ec2d331414caabfd3f84e5aeec3310e2d53746dbff91a415d400` |

Notas de verificación (divergencias respecto del texto del plan `task-5.md`):

- El plan citaba `doc-service` HEAD `944346fa...` (el fix de relay); el HEAD real es `f67c266a...`,
  un commit posterior. El fix de relay sigue incluido y el árbol está limpio. El hash de firma se
  ata al HEAD observado, no al del plan.
- El plan estimaba el commit del worker en `bfbb6fa...`; el HEAD real es `d39dde4...`. El archivo
  `lib.rs` y su hash son los observados; el plan no fija un hash de `lib.rs` distinto.
- El plan citaba `repository.go:119-125` para `WorkMessage`; el bloque real está en
  `repository.go:123-129` (campos en 124-128). Se cita la línea real.
- El valor efectivo de `WORKER_MIN_IDLE_MS` en Compose es `600001` (línea 740), no el default de
  `config.rs` (`601000`). Se registra el efectivo.

## Alcance del congelamiento

Se declara congelado el contrato cuando los cinco elementos siguientes tienen hash y firma; cualquier
cambio posterior exige el procedimiento de `## Reglas de compatibilidad`:

1. Conjunto de campos del mensaje de trabajo: exactamente cinco.
2. Nombres literales: `document_id`, `object_key`, `correlation_id`, `enqueued_at`, `schema_version`.
3. Tipos: cuatro strings y un entero decimal serializado como texto en el stream.
4. `schema_version = 1` como único valor aceptado por el consumidor.
5. Topología de nombres: stream `stream:pdf-processing`, consumer group `extraction-workers`,
   DLQ `stream:pdf-processing-dlq`.

Además, el congelamiento fija el conjunto de campos de la DLQ (diez, ver `## Contrato de la DLQ`)
y dos invariantes observables que no son campos:

- El mensaje NO lleva `attempts`; el conteo de intentos es el *delivery count* de `XPENDING`
  (`docs/SPEC.md:270,277`; `docs/pasos-iniciales.md:889-892`).
- `XACK` del original y `XADD` a la DLQ ocurren en una sola operación atómica
  (`docs/SPEC.md:279-284`; `docs/pasos-iniciales.md:891-892`).

Lo que el congelamiento NO cubre (cambiar solo esta tabla no rompe el contrato ni exige firma nueva):

| Elemento | Estado | Por qué no es parte del contrato |
|---|---|---|
| Orden interno del relay (`UPLOADED → QUEUED` antes del `XADD`) | No congelado, no rompiente | Es una invariante transaccional del productor, no un campo (`relay.go:88-124`). Cambiarla altera cuándo se publica, no qué se publica. |
| Deduplicación `SET NX` + TTL 10 min | No congelada | Detalle del productor (`queue.go:75-83`, TTL en `queue.go:41`). Su remoción produce duplicados, no un mensaje inválido. |
| `WAIT 1` con timeout de 500 ms | No congelado | Reduce la ventana de pérdida, no define el mensaje (`queue.go:108-125`, default en `queue.go:37-42`). |
| Reintentos del relay y backoff | No congelado | `relay.go:158-173`. |
| Nombre del consumidor (`consumer-<host>-<pid>`) | No congelado | Efímero, lo decide el worker (`config.rs:132`). |
| Clave de deduplicación (`dedup:<document_id>`) | No congelada | Detalle del productor (`queue.go:75`). |
| `block_ms`, `count`, `xautoclaim_interval` | No congelados | Parámetros operativos (`config.rs:147-154`). |
| Implementación del replay | No congelada | Su existencia es criterio de G3; su forma no es contrato. |

Regla de lectura: si un cambio altera solo esta segunda tabla, no requiere firma nueva ni
`schema_version=2`. Si altera la primera (campos, nombres, tipos, versión o topología), sí.

## Topología de nombres

| Elemento | Valor | Fuente (file:line) |
|---|---|---|
| Stream | `stream:pdf-processing` | `docs/pasos-iniciales.md:851`; `docs/SPEC.md:265`; default de Compose `infra/compose/docker-compose.yml:633` (`REDIS_STREAM_KEY`) y `:721` (`REDIS_STREAM`) |
| Consumer group | `extraction-workers` | `docs/pasos-iniciales.md:852`; `docs/SPEC.md:266`; default en `config.rs:148`; Compose `infra/compose/docker-compose.yml:722` |
| DLQ | `stream:pdf-processing-dlq` | `docs/pasos-iniciales.md:853`; `docs/SPEC.md:267`; default en `config.rs:156`; Compose `infra/compose/docker-compose.yml:723` (`${REDIS_STREAM_KEY:-stream:pdf-processing}-dlq`) |
| Nombre del maestro Sentinel | `myprimary` | `infra/compose/docker-compose.yml:631` (`REDIS_MASTER_NAME: myprimary`) |

Los defaults de Compose coinciden con la topología normativa. Las corridas de failover usan una clave
de stream aislada (`stream:pdf-processing-s6-failover` y su `-dlq`) para no tocar el stream real; eso
es un override de drill, no la topología del contrato.

## Contrato del mensaje de trabajo

Lado productor (`doc-service`): `WorkMessage` (`internal/ports/repository.go:123-129`) se publica con
un único `XADD` como mapa de campos planos (`internal/adapters/redis/queue.go:86-95`). El
`schema_version` se serializa con `strconv.Itoa` (`queue.go:93`) y la constante `workSchemaVersion = 1`
vive en `cmd/api/main.go:40`.

Lado consumidor (`extraction-worker`): `WorkItem` (`crates/core/src/lib.rs:75-87`) deserializa con
`#[serde(deny_unknown_fields)]` (`lib.rs:76`) y, en el camino de campos planos, con una lista blanca
de cinco nombres (`CONTRACT_FIELDS`, `lib.rs:137-143`).

| # | Campo | Tipo Go | Tipo en el stream | Tipo Rust | Obligatorio | Ejemplo | Fuente productor | Fuente consumidor |
|---|---|---|---|---|---|---|---|---|
| 1 | `document_id` | `string` | bulk string | `String` | Sí | `01J9Z8QK3M7X2V0N4P6R8T1Y0B` | `repository.go:124`; `queue.go:89` | `lib.rs:80`; lista blanca `lib.rs:138`; faltante → `lib.rs:154` |
| 2 | `object_key` | `string` | bulk string | `String` | Sí | `raw-pdfs/01J9Z8QK3M7X2V0N4P6R8T1Y0B.pdf` | `repository.go:125`; `queue.go:90`; derivado en `relay.go:86` | `lib.rs:82`; lista blanca `lib.rs:139` |
| 3 | `correlation_id` | `string` | bulk string | `String` | Sí | `01J9Z8QK3M7X2V0N4P6R8T1Y0B` | `repository.go:126`; `queue.go:91` | `lib.rs:83`; lista blanca `lib.rs:140` |
| 4 | `enqueued_at` | `string` (RFC 3339) | bulk string | `String` (opaco) | Sí | `2026-11-30T10:15:03Z` | `repository.go:127`; formateado en `relay.go:129`; `queue.go:92` | `lib.rs:84-85`; lista blanca `lib.rs:141` |
| 5 | `schema_version` | `int` | bulk string decimal | `u32` | Sí; debe ser `1` | `1` | `repository.go:128`; `strconv.Itoa` en `queue.go:93`; constante en `main.go:40` | `lib.rs:86`; lista blanca `lib.rs:142`; parseo `lib.rs:156-161`; validación `lib.rs:113-117`; `SUPPORTED_SCHEMA_VERSION=1` en `lib.rs:22` |

Notas verificadas:

- `object_key` se deriva, no se recibe: `fmt.Sprintf("raw-pdfs/%s.pdf", event.DocumentID)`
  (`relay.go:86`), lo que materializa la idempotencia de `docs/pasos-iniciales.md:886-887`.
- `enqueued_at` lo genera el relay al publicar (`relay.go:129`), no es el `created_at` de Mongo.
- El productor NO emite `attempts` (`queue.go:86-95`); el consumidor lo rechaza como campo desconocido
  (`lib.rs:144-148`). El conteo de intentos es el delivery count de `XPENDING`
  (`docs/SPEC.md:270,277`).
- `schema_version` viaja como texto decimal porque Redis Streams no tiene tipo entero; el consumidor
  lo parsea con `parse::<u32>()` (`lib.rs:157-161`).
- Verificación explícita de ausencia de `serde(default)` en `lib.rs`: `grep -n 'serde(default' lib.rs`
  no devuelve coincidencias. Ningún campo del `WorkItem` tiene valor por defecto; los cinco son
  obligatorios. Un campo faltante produce `ContractError::Invalid("falta el campo ...")`
  (`lib.rs:150-155`).

Comportamiento del consumidor que el contrato también fija:

| Comportamiento | Efecto observable | Fuente |
|---|---|---|
| Lista blanca de cinco campos en el camino plano | Campo extra → `ContractError::Invalid("campo desconocido: <k>")` | `lib.rs:137-148` |
| `deny_unknown_fields` en serde | Campo extra en el camino `payload` → error de deserialización | `lib.rs:76`, `lib.rs:131-135` |
| `schema_version` distinto de 1 | `UnsupportedSchemaVersion` → DLQ con `error_code: UNSUPPORTED_SCHEMA_VERSION` | `lib.rs:113-117`; `dlq.rs:242-244` |
| Mensaje inválido por campo faltante o desconocido | DLQ con `error_code: INVALID_CONTRACT` | `dlq.rs:245-247` |

## Contrato de la DLQ

Lado consumidor: `DlqMessage` (`crates/core/src/lib.rs:49-67`), serializado como campos planos con
`#[serde(deny_unknown_fields)]` (`lib.rs:50`) y escrito por `move_to_dlq_with_cause`
(`crates/worker/src/consumer/dlq.rs:89-142`).

| # | Campo | Tipo | Origen | Obligatorio | Ejemplo | Fuente (file:line) |
|---|---|---|---|---|---|---|
| 1 | `document_id` | string | copiado del mensaje original | Sí | `01J9Z8QK3M7X2V0N4P6R8T1Y0B` | `lib.rs:52`; `dlq.rs:102` |
| 2 | `object_key` | string | copiado del original | Sí | `raw-pdfs/<id>.pdf` | `lib.rs:53`; `dlq.rs:103` |
| 3 | `correlation_id` | string | copiado del original | Sí | `<id>` | `lib.rs:54`; `dlq.rs:104` |
| 4 | `enqueued_at` | string RFC 3339 | copiado del original | Sí | `2026-11-30T10:15:03Z` | `lib.rs:55`; `dlq.rs:105` |
| 5 | `schema_version` | u32 | copiado del original | Sí | `1` | `lib.rs:56`; `dlq.rs:106` |
| 6 | `delivery_count` | u64 | **`XPENDING`** (no el payload) | Sí | `5` | `lib.rs:58`; sustituido en el script `dlq.rs:70-73`; lectura `dlq.rs:209-222` |
| 7 | `failed_at` | string RFC 3339 | reloj del worker al mover a DLQ | Sí | `2026-11-30T10:17:44Z` | `lib.rs:60`; `dlq.rs:98-100` |
| 8 | `error_code` | string | código estable de `error_code` | Sí | `PDF_CORRUPT` | `lib.rs:62`; catálogo `lib.rs:25-45` |
| 9 | `error_message` | string | mensaje del fallo | Sí | `Failed to parse xref table at offset 91823` | `lib.rs:63`; `dlq.rs:112` |
| 10 | `error_kind` | `ErrorKind` | `business` \| `transient` | Sí | `business` | `lib.rs:66`; `rename_all = "lowercase"` en `lib.rs:176-179` |

Códigos de error estables reconocidos: `INVALID_CONTRACT`, `UNSUPPORTED_SCHEMA_VERSION`,
`MAX_ATTEMPTS_EXCEEDED`, `PDF_CORRUPT`, `PDF_ENCRYPTED`, `PDF_NO_TEXT`, `PDF_TOO_LARGE`,
`PDF_TOO_MANY_PAGES`, `PDF_OUTPUT_TOO_LARGE` (`lib.rs:25-45`).

Atomicidad `XACK` + `XADD`: se ejecutan en un único `EVAL` de un script Lua
(`dlq.rs:58-83`; invocación en `dlq.rs:126-141`). Extracto literal (no se copia el script completo):

```lua
local pending = redis.call('XPENDING', stream, group, id, id, 1)
if type(pending) ~= 'table' or #pending == 0 then
  return 0
end
...
redis.call('XADD', unpack(args))
redis.call('XACK', stream, group, id)
```

| Propiedad | Cómo se garantiza | Fuente |
|---|---|---|
| Atomicidad | Un único `EVAL`; Redis no deja efectos parciales | `dlq.rs:58-83`, `dlq.rs:126-141` |
| Idempotencia | Si el id ya no está pendiente, `return 0` y no escribe nada | `dlq.rs:63-66`, `dlq.rs:85-88` |
| `delivery_count` fresco | Se lee del `XPENDING` dentro del script y reemplaza el placeholder `0` | `dlq.rs:67`, `dlq.rs:70-73`, `dlq.rs:109` |

Consecuencia contractual: `delivery_count` no lo "escribe" el productor ni el worker; es el valor que
Redis mantiene en la PEL. El placeholder `0` de `dlq.rs:109` nunca llega al stream porque el script lo
sustituye antes del `XADD`.

Calibración de `min-idle-time` (regla `min-idle-time ≥ 2 × job_timeout`, `docs/SPEC.md:286`):

| Dato | Valor observado | Fuente |
|---|---|---|
| `WORKER_JOB_TIMEOUT_SECS` efectivo en Compose | `300` s | `infra/compose/docker-compose.yml:738` |
| `WORKER_MIN_IDLE_MS` efectivo en Compose | `600001` ms | `infra/compose/docker-compose.yml:740` |
| Default derivado en código | `job_timeout_secs * 2000 + 1000` = `601000` ms | `config.rs:137` |
| Cumplimiento | `600001 ≥ 2 × 300000 = 600000` → cumple con 1 ms de margen | cálculo sobre los valores efectivos |

Nota: el valor efectivo de Compose (`600001`) es menor que el default derivado (`601000`), pero sigue
cumpliendo la regla con 1 ms de margen. Un valor explícito de `WORKER_MIN_IDLE_MS` por debajo de
`2 × job_timeout` rompería la regla sin que el código lo detecte.

## Diff productor/consumidor

Comparación explícita:

| Campo | Productor | Consumidor | Veredicto |
|---|---|---|---|
| `document_id` | `string` | `String` requerido | Coincide |
| `object_key` | `string` | `String` requerido | Coincide |
| `correlation_id` | `string` | `String` requerido | Coincide |
| `enqueued_at` | `string` RFC 3339 | `String` requerido, opaco | Coincide (el productor emite RFC 3339; el consumidor no lo parsea) |
| `schema_version` | `int` → texto decimal | `u32` parseado, debe ser `1` | Coincide |

Conteos:

| Conjunto | Cantidad |
|---|---|
| Campos del productor | 5 |
| Campos del consumidor (camino plano) | 5 |
| Solo en el productor | 0 |
| Solo en el consumidor | 0 |
| Campo opcional en cualquiera de los dos lados | 0 |
| Campo con valor por defecto | 0 |

Regla de veredicto: el contrato es congelable si y solo si (1) el conjunto de nombres es idéntico en
ambos lados, (2) no hay campos solo-productor ni solo-consumidor, (3) cada campo requerido por un lado
lo emite siempre el otro, y (4) los tipos son compatibles en el borde del stream. Un campo requerido
por un lado y ausente en el otro bloquearía el congelamiento.

Veredicto observado: nombres 5/5 idénticos (mismo casing `snake_case`); solo-productor 0;
solo-consumidor 0; requeridos alineados 5/5; tipos compatibles (`int` Go → texto decimal → `u32`
Rust; un valor negativo o no numérico cae en `ContractError::Invalid`, `lib.rs:156-161`).
Veredicto: COMPATIBLE — congelable, sujeto a las firmas de `## Firmas` y a las erratas de
`## Hallazgos y erratas`.

## Reglas de compatibilidad

Con este código, "agregar un campo es aditivo" es FALSO: ambos lados aplican estrictez total. El
consumidor rechaza cualquier campo fuera de la lista blanca (`lib.rs:137-148`) y `deny_unknown_fields`
refuerza lo mismo en el camino `payload` (`lib.rs:76`). Regla literal de `docs/pasos-iniciales.md:895-896`:

> `deny_unknown_fields` en ambos lados: un campo inesperado es un error de contrato visible, no un
> bug silencioso.

No se reformula como "los consumidores ignoran campos desconocidos": en este código hacen lo
contrario y esa es la decisión vigente.

| Cambio | ¿Compatible con consumidores v1 ya desplegados? | Clasificación |
|---|---|---|
| Agregar un campo nuevo (incluido `enqueued_at` si faltara) | No: `INVALID_CONTRACT` por campo desconocido | Rompiente |
| Quitar un campo | No: falta el campo | Rompiente |
| Renombrar un campo | No: falta uno y sobra otro | Rompiente |
| Cambiar `schema_version` de 1 a 2 sin tocar campos | No: `UNSUPPORTED_SCHEMA_VERSION` | Rompiente (deliberado) |
| Cambiar `enqueued_at` de RFC 3339 a epoch | Type-compatible, semánticamente rompiente para herramientas | Rompiente por convención |
| Cambiar `object_key` a una ruta distinta | Rompe la idempotencia derivada | Rompiente |
| Cambiar el orden del relay | Sin efecto sobre el mensaje | No rompiente |
| Cambiar el TTL de dedup | Sin efecto sobre el mensaje | No rompiente |

Procedimiento para `schema_version=2`:

1. Congelar 1 primero; un v2 sin v1 firmado no tiene línea base de compatibilidad.
2. Bump explícito: todo cambio de campo exige `schema_version=2`; no existe "v1 con un campo extra".
3. Consumidor primero, productor después: el worker v2 debe aceptar 1 y 2 antes de que el relay emita 2.
   Hoy `validate_schema` acepta solo `== SUPPORTED_SCHEMA_VERSION` (`lib.rs:113-117`), así que soportar
   dos versiones exige cambiar el código del consumidor, no un flag.
4. Ventana de doble aceptación: el worker v2 traduce ambos formatos a la misma estructura interna; el
   relay sigue emitiendo 1 hasta que el 100 % de los consumidores sean v2.
5. Corte del productor: el relay pasa a `schema_version=2`; `WAIT 1` y la dedup no cambian.
6. Sin rollback ambiguo: volver a 1 se hace con el mismo procedimiento invertido y un replay de los
   mensajes 2 ya emitidos; no se "edita" el stream.
7. Nombres de stream, grupo y DLQ no son mecanismo de versionado. Renombrarlos es un cambio de
   infraestructura con replay coordinado. Si se necesita aislar tráfico incompatible sin ventana de
   doble aceptación, se usa un stream nuevo explícito (`stream:pdf-processing-v2`, `...-v2-dlq`) y se
   declara como migración, no como v2 del mismo stream.

## Hallazgos y erratas

| ID | Hallazgo | Evidencia | Efecto y decisión |
|---|---|---|---|
| H-01 | El ejemplo de DLQ de `docs/pasos-iniciales.md:869-880` lista 9 campos y omite `enqueued_at`, pero el código lo exige como campo no opcional de `DlqMessage` (`lib.rs:55`) y el worker lo emite siempre (`dlq.rs:105`). | `docs/pasos-iniciales.md:869-880` vs. `lib.rs:51-67` vs. `dlq.rs:101-114` | Bloquea la firma de P3 sobre la DLQ, no la del mensaje de trabajo. Se resuelve como errata: el contrato de facto de la DLQ es de 10 campos. Corregir el doc o eliminar el campo es decisión de P2/P3, fuera de esta tarea. |
| H-02 | `docs/SPEC.md:290` (§5.5) menciona `attempts` como campo del mensaje; contradice §5.4 (`docs/SPEC.md:270,277`) y a ambos lados del código. | `docs/SPEC.md:290` vs. `:270,277` vs. `queue.go:86-95` vs. `lib.rs:75-87` | No bloquea. Se congela §5.4 como autoritativo y se pide errata de §5.5 en la revisión de arquitectura. |
| H-03 | El consumidor acepta un campo único `payload` con el JSON del contrato además de los campos planos (`lib.rs:131-135`); el productor emite solo la forma plana (`queue.go:86-95`). | `lib.rs:130-135`; `queue.go:86-95` | No bloquea. Rama no contractual, muerta en producción: si alguien la usa, no está usando el contrato congelado. No es un mismatch de campos. |

## Firmas

Contrato: `schema_version=1` · stream `stream:pdf-processing` · group `extraction-workers` · dlq `stream:pdf-processing-dlq`

| Lado | Commit | SHA-256 del archivo | Firmante | Fecha (UTC) | Estado |
|---|---|---|---|---|---|
| Productor | `f67c266aa98f779b890bfb1c659a46bc2e2c3d36` | `682bf9ae9874e33043204d7926d80b0441d956f3f884689a2456c5f425738080` (`queue.go`) | P2 | pendiente | PENDIENTE |
| Consumidor | `d39dde42e58a9b19e341c7f39ce8ec3185dc83b6` | `1a3edf8a4856480f334ab013fd115357aff6f928d37c0c2bac36a669dbc69746` (`lib.rs`) | P3 | pendiente | PENDIENTE |

Estado del contrato: **BORRADOR**. Se declara CONGELADO solo si ambas filas dicen FIRMADO. Como ambas
filas dicen PENDIENTE, este documento es BORRADOR y no puede citarse como contrato congelado hasta que
P2 y P3 firmen. No se inventan firmas ni fechas: las fechas (UTC) se completan al firmar.

Atestaciones que cada firma cubre:

- P2 (productor): (a) `queue.go` y `relay.go` en el commit firmado emiten exactamente los cinco campos
  de `## Contrato del mensaje de trabajo`; (b) `schema_version` es `1`; (c) el SHA-256 declarado
  corresponde al archivo leído; (d) no hay cambio pendiente sin commitear en `doc-service`; (e) acepta
  que el orden del relay no forma parte del contrato congelado.
- P3 (consumidor): (a) `WorkItem` acepta exactamente esos cinco campos y ninguno más; (b)
  `SUPPORTED_SCHEMA_VERSION = 1`; (c) `DlqMessage` tiene los diez campos y la atomicidad Lua declarada;
  (d) el SHA-256 declarado corresponde al archivo leído; (e) resuelve o acepta por escrito la errata H-01
  antes de firmar.

Regla de invalidez: sin las dos firmas, el contrato NO está congelado; una sola firma deja el artefacto
en BORRADOR. La firma se ata a los hashes, no a la fecha: si un hash cambia tras firmar, la firma queda
inválida y hay que volver a firmar. Un cambio en lo listado en `## Alcance del congelamiento` como "no
cubierto" no invalida la firma; un cambio en los campos, nombres, tipos, versión o topología sí.

## Checklist G3

Texto literal de la puerta (`docs/pasos-iniciales.md:247`, transcrito sin normalizar tildes):

> | G3 -> F4 | Fin S6 | DLQ y replay funcionando, 100 % de estados terminales tras el failover, recuperacion de los mensajes perdidos por el failover medida | DLQ en modo pasivo; se replica la extraccion en paralelo sin escribir |

Regla de decisión (`docs/pasos-iniciales.md:239-240`): "No se avanza de fase sin cumplir su puerta. La
decision se toma en la revision de arquitectura del miercoles y queda registrada como ADR o nota de
decision."

P1 NO declara Go. P1 prepara el checklist y lo entrega; la decisión es de la revisión de arquitectura.

| # | Ítem de G3 (literal) | Evidencia enlazada | Estado (2026-11-15) |
|---|---|---|---|
| G3.1 | `DLQ y replay funcionando` | DLQ atómica en código: `dlq.rs:58-83`, `dlq.rs:126-141`; contrato DLQ en `## Contrato de la DLQ`; alerta de DLQ no vacía `DLQNotEmpty` en `S6-P1-03-revision-alertas.txt`; en la corrida válida la DLQ terminó vacía (`XLEN DLQ=0`, `S6-P1-01-failover-carga-run4.txt` §11). La corrida de replay observada NO existe. | Parcial (no verificado) |
| G3.2 | `100 % de estados terminales tras el failover` | `S6-P1-01-failover-carga-run4.txt` §9: "COMPLETED=303, no terminales=0"; §16: "100 % terminal: PASA (303/303, 0 no terminales)". Desvíos de método declarados en el mismo artefacto (concurrencia 1, fixture de 400 páginas). | Cumple |
| G3.3 | `recuperacion de los mensajes perdidos por el failover medida` | `S6-P1-01-failover-carga-run4.txt` §6: `XLEN_PRE=302`, `XLEN_POST=302`, `PERDIDOS=0`; §10: "PERDIDOS=0 => recuperacion no ejercida; T_recovered=N/A". La pérdida bajo carga se midió (0), pero la recuperación de mensajes perdidos no se ejerció. | Parcial (no verificado) |

Notas de honestidad:

- `Cumple` solo se usa en G3.2 porque la corrida válida muestra explícitamente los números observados
  (303/303 terminales, 0 no terminales). No se subió ningún ítem a `Cumple` por inspección de código.
- G3.1 queda `Parcial (no verificado)`: la DLQ atómica está implementada y el contrato la fija, pero la
  corrida de replay no está observada.
- G3.3 queda `Parcial (no verificado)`: hay medición de pérdida (0), pero la recuperación por
  reconciliador no se ejerció (`T_recovered=N/A`), así que la recuperación en sí no está medida.
- `S6-P1-01-failover-carga.txt` es el intento DESCARTADO (`dc stop` provocó tilt de Sentinel con
  `NOGOODSLAVE No suitable replica to promote`, `MASTER_NUEVO=N/A`); se cita solo como justificación de
  usar `pause` en la corrida válida.
- Gaps abiertos que impiden declarar G3 Go: G3.1 y G3.3 en `Parcial`. La decisión y la contingencia
  (`DLQ en modo pasivo; se replica la extraccion en paralelo sin escribir`) corresponden a la revisión
  de arquitectura, no a P1.
