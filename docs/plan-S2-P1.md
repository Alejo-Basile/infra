# Plan de Ejecución — Semana 2, P1 (Platform / DevOps / SRE)

> **Documento de ejecución semanal.** Deriva de `plan-P1.md` §3.3, `pasos-iniciales.md` §6.2 y
> `SPEC.md` v2.1. Es la continuación directa de `plan-P1-S1.md` (§11 "Herencia para S2").
> S1 cerró la **base estructural** (Traefik + TLS, MinIO + buckets + ACL, Redis AOF, Mongo RS,
> observabilidad base, exposición S3 por host dedicado). S2 cierra la **Fase 1**: hardening,
> alta disponibilidad de Redis (Sentinel), alertas accionables, backups **probados restaurando**,
> gestión de secretos y la **puerta G1 — Go/No-Go de Fase 1**.

| Campo | Valor |
|---|---|
| Semana | S2 (Fase 1 — Hardening y Go/No-Go) |
| Fechas | lun 2026-10-12 → vie 2026-10-16 |
| Owner | P1 |
| Pair obligatorio | **Vie** — ensayo de failover de Sentinel + restauración de Mongo (con P2/P3 para verificar la reconexión de los clientes) |
| Hito de cierre | **Puerta G1 — Go/No-Go de Fase 1** (vie 16/10) |
| Entorno | **Local / académico** (ADR-0016: `api.localhost`, `s3.localhost`, HTTP 8088 / HTTPS 8543) |

---

## 1. Punto de partida: qué dejó S1 y qué se hereda

S1 terminó con la base verificada en runtime y 5 commits en
`feat/infra-s1-fuego-observability`. S2 **no rehace** nada de eso: cierra lo que quedó
explícitamente heredado y agrega la capa de operación (HA, alertas, backups, secretos).

| Tarea | Estado al cierre de S1 | Trabajo restante en S2 |
|---|---|---|
| `S1-P1-01` Traefik + TLS | **HECHO** (redirect 301, cert por host, router `s3-api` solo al 9000) | Ninguno (V-01 en verde). |
| `S1-P1-02` Buffering 413 + `EntityTooLarge` | **HECHO completo** (partes a y b, adelantado de S3) | Ninguno. |
| `S1-P1-04/05` Buckets + identidades | **HECHO** (`permisos-minio.md`, `AccessDenied` verificado) | `S1-P1-06` (lifecycle) se apoya en esto. |
| `S1-P1-07` Redis AOF | **HECHO** (`XADD` sobrevive a restart) | `S1-P1-08` (Sentinel) se apoya en esto. |
| `S1-P1-09/10` Mongo RS + usuarios | **HECHO** (`rs0` PRIMARY, rol worker solo `update`+`find`) | `S1-P1-14` (backups) se apoya en esto. |
| `S1-P1-11` Índices + TTL gracia | **VERIFICADO** (4 índices, runbook `mongo-ttl.md`) | Ninguno. |
| `S1-P1-12` Observabilidad | **PARCIAL aceptado** (scrape doc-service `up`, dashboard v1) | `S1-P1-13` (alertas) se apoya en esto. |
| `S1-P1-16` Exposición S3 | **HECHO** (router 9000, anónimo 403, SigV4 pos/neg) | Ninguno. |

### 1.1 Herencia explícita (de `plan-P1-S1.md` §11)

Estas tareas **no se empezaron a medias en S1 a propósito**; se ejecutan enteras en S2 con su
ensayo:

| ID | Tarea | Prio | Depende de |
|---|---|---|---|
| `S1-P1-03` | TLS y mTLS interno (**opcional**) | P2 | `S1-P1-01` |
| `S1-P1-06` | Lifecycle en los buckets | P1 | `S1-P1-04` |
| `S1-P1-08` | Topología de Streams: Sentinel 3 nodos | P1 | `S1-P1-07` |
| `S1-P1-13` | Alertas accionables | P1 | `S1-P1-12` |
| `S1-P1-15` | Hardening de contenedores | P1 | `S1-P1-12` |
| `S1-P1-14` | Backups verificados restaurando | P0 | `S1-P1-09` |
| `S2-P1-01` | Gestión de secretos + rotación | P0 | `S1-P1-14` |

### 1.2 Estado inicial del stack (verificado)

- 10 servicios `infra-*` con perfil `full` (7 con healthcheck + `grafana`, `loki`, `prometheus`).
- Hardening **parcial ya aplicado** en `compose/docker-compose.yml` (anclas `*hardening` y
  `*hardening-data`): `cap_drop: ["ALL"]`, `security_opt: no-new-privileges`, `restart`,
  `mem_limit`, `pids_limit`. **S1-P1-15 completa lo que falta**: `read_only`, usuario no-root
  explícito y auditoría `docker inspect`.
- Prometheus con jobs `traefik:8082` y `doc-service:8080` (`prometheus.yml`, 5 s scrape).
  **Sin Alertmanager y sin reglas**: eso es S1-P1-13.
- Redis Streams: instancia única (`streams.conf`, AOF `everysec`, `noeviction`). **Sin Sentinel**.
- Mongo `rs0` de un solo nodo. **Sin backup automatizado ni procedimiento de restauración probado**.
- Secretos viven en `infra/.env` (git-ignored) y se inyectan por `environment:`. **No hay
  secret store del orquestador**: eso es S2-P1-01.

---

## 2. Objetivo de la semana

Convertir la base funcional de S1 en una **base operable y endurecida**: Redis deja de ser punto
único de fallo (Sentinel + ensayo de failover), las métricas se vuelven alertas que dicen **qué
hacer**, hay un backup de Mongo **restaurado y verificado**, los contenedores quedan endurecidos
según SPEC §9, y los secretos salen del `.env` hacia el secret store del orquestador con rotación
documentada. La semana cierra en la **puerta G1**.

---

## 3. Calendario día a día

| Día | Foco | Tareas | Hito |
|---|---|---|---|
| Lun 12/10 | Decisión mTLS + arranque de HA | `S1-P1-03` (decisión), diseño Sentinel | mTLS decidido (hecho o deuda con owner/fecha); topología Sentinel diseñada |
| Mar 13/10 | Lifecycle + Sentinel montado | `S1-P1-06`, `S1-P1-08` | Borrado por lifecycle probado; Sentinel 3 nodos en pie |
| Mié 14/10 | Alertas + hardening | `S1-P1-13`, `S1-P1-15` | Cada alerta dispara y trae su acción; `docker inspect` audita el hardening |
| Jue 15/10 | Backups + secretos | `S1-P1-14`, `S2-P1-01` | Restauración de Mongo verificada; secretos en el store + rotación documentada |
| Vie 16/10 | Ensayos + cierre | Ensayo failover + restore; runbooks v1 | **G1 — Go/No-Go de Fase 1** |

> **Nota de calendario (ADR-0016):** las fechas del plan genérico (`pasos-iniciales.md` §6.2)
> asumen un despliegue con staging remoto. En local los ensayos se corren sobre el perfil `full`.

---

## 4. Detalle de tareas (pasos, DoD, rollback, evidencia)

Convenciones: se trabaja desde `infra/` salvo que se indique. Guardar la salida de cada
verificación en `infra/docs/evidencias/S2/` (crear el directorio). Cada comando destructivo
lleva su paso de rollback. Los puertos reales son **8088/8543** (no 80/443).

### `S1-P1-03` — Decisión de TLS/mTLS interno (lun 12/10)

**Es una decisión, no una implementación obligatoria** (ADR-0020). La cobertura mínima ya existe
(aislamiento de red: `data`/`internal` sin salida a internet + secreto compartido del webhook).
La tarea termina con **una de dos** salidas registradas:

1. **Se implementa:** CA interna con `openssl`/`step-ca`, un certificado por servicio, y Traefik
   valida el certificado de cliente **solo en rutas internas**.

   ```bash
   # CA + cert por servicio (nombres de ejemplo)
   infra/scripts/gen-internal-ca.sh         # CA interna + certs a traefik/certs/internal/
   # Traefik: TLS con clientAuth en el router interno
   #   tls:
   #     options:
   #       internal:
   #         clientAuth:
   #           caFiles: [/certs/internal/ca.crt]
   #           clientAuthType: RequireAndVerifyClientCert
   # Verificación:
    curl -sk https://api.localhost:8543/internal/health            # sin cert -> rechazado (400/403) # gitleaks:allow
    curl -sk --cert services/worker.crt --key services/worker.key \
         https://api.localhost:8543/internal/health                # con cert -> 200 # gitleaks:allow
   ```

2. **Se decide NO hacerlo en la v1** y queda **deuda declarada con owner y fecha** en
   `SPEC.md` §9 / `pasos-iniciales.md` §19.3 (no como tarea abierta).

- **DoD**: una ruta interna rechaza la llamada sin certificado y la acepta con el correcto
  **o** la deuda está escrita con owner (`P1`) y fecha de revisión, y no queda como tarea abierta.
- **Rollback**: si se implementa, revertir el `clientAuth` de Traefik (las rutas vuelven a
  confiar en el aislamiento de red).
- **Evidencia**: `S1-P1-03-mtls.txt` (caso implementado) o `S1-P1-03-deuda.md` (decisión + owner + fecha).
- **Recomendación**: dado que no bloquea ninguna puerta y agregarlo a los 4 componentes retrasa
  el calendario sin cerrar el vector real (suplantación del cliente, ya cubierta por credenciales
  por bucket + rol Mongo acotado), **registrar la deuda** es la salida honesta salvo que sobre tiempo.

### `S1-P1-06` — Lifecycle en los buckets (mar 13/10)

`raw-pdfs`: eliminar el objeto tras N días **o** al completar el procesamiento.
`extracted-txt`: según requisito de negocio (retención).

```bash
# Ver/crear la regla con mc (desde infra/)
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  bitnamilegacy/minio-client:2025.7.21 ilm rule add \
    --expire-days 7 --prefix "" local/raw-pdfs
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  bitnamilegacy/minio-client:2025.7.21 ilm rule ls local/raw-pdfs

# Prueba manual del borrado: forzar una expiración corta y verificar que el objeto desaparece
#  (subir un objeto de prueba, aplicar --expire-days 0/1, esperar el ciclo del scanner de MinIO)
```

> **Nota:** MinIO aplica el lifecycle por su scanner interno (no instantáneo). La prueba usa una
> expiración muy corta + `mc ilm rule`, y se documenta el tiempo observado.

- **DoD**: la regla `ilm` existe en `raw-pdfs` y en `extracted-txt`; una prueba manual confirma
  que un objeto de prueba es recolectado. Regla versionada (script idempotente en `minio/`).
- **Rollback**: `mc ilm rule rm --id <id> local/raw-pdfs`.
- **Evidencia**: `S1-P1-06-lifecycle.txt` (+ script en `compose/minio/`).

### `S1-P1-08` — Sentinel 3 nodos para Streams (mar 13/10)

**Objetivo**: que Redis deje de ser punto único de fallo. Topología local:

```
redis-streams (primario)  +  redis-streams-replica-1, redis-streams-replica-2
sentinel-1, sentinel-2, sentinel-3  (quorum 2)
```

> **Este es el cambio más invasivo de la semana**: agrega 5 contenedores y **cambia el endpoint
> del cliente** (de `redis-streams:6379` a `sentinel-1:26379`). Coordinar con **P2 (Go)** y
> **P3 (Rust)**: sus clientes deben ser **Sentinel-aware** (resolver el primario en cada
> reconexión, con backoff + jitter). Un cliente que no lo es funciona en integración y se cae
> el día del failover (SPEC §3.5).

Pasos:
1. Crear `compose/redis/sentinel.conf.tmpl` (`sentinel monitor myprimary redis-streams 6379 2`,
   `down-after-milliseconds`, `failover-timeout`, `auth-pass`).
2. Añadir a `docker-compose.yml` (perfil `full`): `redis-streams-replica-1/2` (con `replicaof`)
   y `sentinel-1/2/3`, todos con el ancla de hardening y en la red `data`.
3. Aplicar `streams.conf` (AOF `everysec`, `noeviction`) a primario **y réplicas**.
4. **Documentar que la replicación es asíncrona**: un failover puede perder los `XADD` no
   replicados; eso lo reduce el `WAIT 1` del relay (P2) y lo recupera el reconciliador (§6.5).
   `AOF` protege contra caída del proceso, **no** contra la pérdida de la réplica.

- **DoD (plan-P1.md)**: se mata el primario y la escritura de mensajes continúa con **< 30 s**
  de interrupción. **El criterio NO incluye "0 mensajes perdidos"**: si se pierden, se cuentan y
  se reportan (eso lo mide `S6-P1-01`).
- **Rollback**: quitar los 5 servicios nuevos y devolver el endpoint del cliente a
  `redis-streams:6379` (bloque `docker-compose` por rama `feat/infra-s2-sentinel`).
- **Evidencia**: `S1-P1-08-sentinel.txt` (INFO replication, `SENTINEL get-master-addr-by-name`,
  y conteo de mensajes antes/después del failover).

### `S1-P1-13` — Alertas accionables (mié 14/10)

Agregar **Alertmanager** + reglas de Prometheus. Cada alerta lleva **la acción escrita en la
anotación** (`description`/`runbook_url`), no solo el síntoma. Alertas mínimas (plan-P1.md):

| Alerta | Señal | Umbral | Acción (anotación) |
|---|---|---|---|
| `QueueDepthHigh` | `XLEN stream:pdf-processing` | > 500 por 5 min | Escalar worker (`--scale extraction-worker=N`) según runbook |
| `PELBacklog` | PEL pendiente (`XPENDING`) | > 100 por 10 min | Revisar workers caídos; `XAUTOCLAIM` |
| `DLQNotEmpty` | `XLEN stream:pdf-processing-dlq` | > 0 | Revisar mensajes; reintentar tras corregir causa |
| `HighErrorRate` | `rate(http_requests_total{code=~"5.."})` | > 1% por 5 min | Revisar logs del servicio; rollback si es deploy |
| `LatencyP95High` | histograma doc-service | > 500 ms p95 por 5 min | Revisar Mongo/Redis; considerar escalar |
| `MinioDiskHigh` | disco de MinIO | > 70% / > 85% | Purgar huérfanos; ampliar volumen |
| `RedisMemHigh` | `used_memory` de streams | > 80% de `maxmemory` | Revisar consumidores lentos (noeviction: la escritura fallará) |
| `DocsNonTerminal` | docs en estado intermedio (`UPLOADED`/`PROCESSING`) | > umbral por 15 min | Revisar reconciliador; forzar sweep |

Pasos:
1. Añadir `prometheus/alert.rules.yml` y `prometheus/alertmanager.yml`; sumar job `redis`
   (`redis-exporter`) y el endpoint de métricas de MinIO (`/minio/v2/metrics/cluster`).
2. Montar Alertmanager en el perfil `full` y rutear (en local, un receiver `webhook`/log).
3. **Probar provocando cada condición a propósito** (llenar la DLQ con `XADD`, simular error 5xx).

- **DoD**: cada alerta dice **qué hacer**; se demuestra disparándose al provocar la condición.
- **Rollback**: `git revert` de las reglas + recrear `prometheus`/`alertmanager`.
- **Evidencia**: `S1-P1-13-alerts.txt` (alertas `firing` en la UI de Alertmanager) + `alert.rules.yml`.

### `S1-P1-15` — Hardening de contenedores (mié 14/10)

Completar lo que el ancla actual **no** cubre: **`read_only: true`** y **usuario no-root
explícito**, más la **auditoría `docker inspect`** de las 5 cosas (plan-P1.md):

| Control | Presente en S1 | Falta en S2 |
|---|---|---|
| `cap_drop: ["ALL"]` | ✅ | — |
| `security_opt: no-new-privileges` | ✅ | — |
| `pids_limit` | ✅ | — |
| Usuario no-root | parcial (imágenes lo traen) | declararlo/auditarlo explícito |
| `read_only: true` + `tmpfs` | ❌ | agregar donde el servicio no escriba en disco |

```bash
# Auditoría: las 5 cosas en todas las imágenes
for c in $(docker compose --profile full ps -q); do
  docker inspect "$c" --format '{{.Name}}: User={{.Config.User}} CapDrop={{.HostConfig.CapDrop}} \
    ReadOnly={{.HostConfig.ReadonlyRootfs}} NoNewPriv={{.HostConfig.SecurityOpt}} Pids={{.HostConfig.PidsLimit}}'
done
```

- **DoD**: `docker inspect` confirma **las cinco cosas** en todas las imágenes. `read_only` solo
  donde el servicio no necesite escribir (los que sí, llevan `tmpfs` acotado: ej. `/tmp`).
- **Rollback**: quitar `read_only` del servicio que falle por necesitar escritura; usar `tmpfs`.
- **Evidencia**: `S1-P1-15-hardening.txt` (salida del bucle de `docker inspect`).

### `S1-P1-14` — Backups verificados **restaurando** (jue 15/10)

**DoD es restaurar, no crear el snapshot.** Snapshot de Mongo + ciclo de vida de buckets +
procedimiento de restauración, probado en un entorno limpio.

```bash
# 1. Snapshot
docker exec infra-mongo-1 mongodump --oplog -u "$MONGO_ROOT_USER" -p "$MONGO_ROOT_PASSWORD" \
  --authenticationDatabase admin --archive >/tmp/mongo-$(date +%F).archive
# 2. Restaurar en un contenedor Mongo LIMPIO (sin datos) apuntando a un volumen aparte
docker run --rm --network infra_data -v /tmp:/backup \
  -e MONGO_INITDB_ROOT_USERNAME=... -e MONGO_INITDB_ROOT_PASSWORD=... \
  docker.io/library/mongo:7 sh -c 'mongorestore --archive=/backup/mongo-XXX.archive --oplogReplay'
# 3. Comparar integridad: conteo por estado antes/después
docker exec infra-mongo-1 mongosh --quiet ... --eval 'db.documents.aggregate([{$group:{_id:"$status",n:{$sum:1}}}])'
```

- **DoD**: se restauró una copia en un entorno **limpio** y se comprobó la **integridad** de los
  datos (conteos por estado consistentes). Procedimiento escrito en `runbooks/restore-mongo.md`.
- **Rollback**: n/a (el restore es en un contenedor aparte; no toca la base viva).
- **Evidencia**: `S1-P1-14-restore.txt` + `runbooks/restore-mongo.md`.

### `S2-P1-01` — Gestión de secretos + rotación (jue 15/10)

Mover los secretos de `environment:` (`.env`) a **Docker secrets** (`secrets:` + archivos
montados en `/run/secrets`), de modo que **no queden en variables de entorno en archivos
commiteados**.

```yaml
# docker-compose.yml
secrets:
  mongo_root_password: { file: ./secrets/mongo_root_password.txt }
  redis_streams_password: { file: ./secrets/redis_streams_password.txt }
  minio_root_password: { file: ./secrets/minio_root_password.txt }
services:
  mongo:
    secrets: [mongo_root_password]
    # el entrypoint lee /run/secrets/mongo_root_password en vez de $MONGO_ROOT_PASSWORD
```

Pasos:
1. `infra/secrets/` **git-ignored** (con `.gitkeep`); generar los archivos localmente.
2. Referenciar en compose y ajustar los entrypoints/`init` para leer `/run/secrets/*`.
3. **Escáner de secretos en CI** (gitleaks) que falle si encuentra algo — ya hay rastro en
   `docs/evidencia-gitleaks-local.txt`.
4. **Documentar la rotación** de un secreto en `runbooks/rotacion-secretos.md`
   (generar → reemplazar archivo → recrear servicios → verificar).

- **DoD**: el escáner de CI no encuentra secretos; la rotación de **un** secreto está documentada
  y ejecutada al menos una vez.
- **Rollback**: volver a `environment:` (temporal) solo si un servicio no lee el secret.
- **Evidencia**: `S2-P1-01-secrets.txt` + `runbooks/rotacion-secretos.md`.
- **Nota**: en Compose no hay `docker secret` gestionado (eso es Swarm/K8s); se usa el mecanismo
  de `secrets` file-based, que es el equivalente correcto para este entorno local/académico.

### Ensayo final (vie 16/10) — failover de Sentinel + restauración de Mongo

Repetir, como **ensayo cronometrado y con evidencia**, dos ensayos ya preparados durante la semana:

1. **Failover de Sentinel**: `docker stop` del primario → medir tiempo hasta que Sentinel promueve
   una réplica y la escritura continúa (< 30 s). Verificar que **los dos clientes (Go y Rust)
   reconectan solos** (logs de P2/P3). Contar mensajes perdidos si los hay.
2. **Restauración de Mongo**: correr `runbooks/restore-mongo.md` de punta a punta y confirmar que
   el estado es consistente con los objetos en MinIO.

- **Evidencia**: `S2-ensayo-failover.txt`, `S2-ensayo-restore.txt`.

---

## 5. Señales de verificación de la semana

| Horizonte | Señal | Cómo medirla |
|---|---|---|
| Inmediata (0–2 min) | Regla `ilm` existe; parser de auditoría devuelve las 5 propiedades; secretos en `/run/secrets` | `mc ilm rule ls`, bucle `docker inspect`, `ls /run/secrets` |
| Corta (2–5 min) | Cada alerta dispara al provocarla; el objeto de prueba es recolectado por lifecycle | UI Alertmanager `firing`, `mc ls` tras el scanner |
| Media (5–15 min) | Failover de Sentinel < 30 s con clientes reconectando; restore de Mongo con integridad | ensayos del viernes con cronómetro |
| Cierre de semana | Evidencias S2 publicadas + runbooks v1 + **G1 en verde** | demo + tablero |

---

## 6. Rollback general de la semana

- Todo cambio va por rama `feat/infra-s2-*` → PR → `main`. Rollback de config = `git revert` +
  `docker compose up -d <servicio>`.
- **Sentinel** es el único cambio estructural grande: se desarrolla en su **propia rama**
  (`feat/infra-s2-sentinel`) para poder descartarla sin arrastrar el resto de S2.
- **Backups/restore** no tocan la base viva (se restauran en contenedores aparte).
- **Secretos**: migración incremental servicio por servicio; si uno falla, se revierte ese
  servicio a `environment:` mientras se corrige el entrypoint.
- Si el stack queda inestable: `docker compose --profile full down && up -d` con la última
  config de `main` (los volúmenes sobreviven; `mongo-init`/`minio-init` son idempotentes).

---

## 7. Comunicación

| Momento | Canal | Contenido |
|---|---|---|
| Lun (planning) | Daily + tablero | Punto de partida (§1): S1 cerrado, herencia de S2 publicada |
| Lun | A P2/P3 | **Anticipar Sentinel**: sus clientes deben ser Sentinel-aware antes del ensayo del viernes |
| Mié | Canal del equipo | Decisión mTLS registrada (hecho o deuda con owner/fecha) |
| Jue | A P2/P3 | Coordinar el ensayo de failover del viernes (verificación de reconexión) |
| Vie (cierre) | Revisión + retro | **G1 — Go/No-Go**: evidencias, runbooks v1 y resultado de los ensayos |

---

## 8. Qué NO hacer en S2 (guardarraíles)

1. **No prometer "0 mensajes perdidos"** en el failover de Sentinel: la replicación es asíncrona.
   La meta es **recuperación < 30 s** + pérdida **medida** (eso lo cierra `S6-P1-01`).
2. **No subir `maxmemory` de Redis para "arreglar" `noeviction`**: la escritura debe **fallar y
   alertarse**, nunca desalojar mensajes del stream.
3. **No romper el aislamiento de red**: los servicios de `data`/`internal` no ganan salida a
   internet por agregar Sentinel o exporters.
4. **No commitear secretos ni archivos de `infra/secrets/`**: van git-ignored; el CI los escanea.
5. **No reconfigurar el router `legacy` del monolito** (no lleva `body-limit-1mb` a propósito).
6. **No implementar mTLS "a medias"**: o queda probado, o queda como **deuda declarada** con
   owner y fecha. No hay tercera opción.

---

## 9. Riesgos de la semana

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| Sentinel rompe el endpoint del cliente (P2/P3 no Sentinel-aware) | Media | Alto — el pipeline se detiene si se cambia antes de que los clientes lo soporten | Dejar `redis-streams:6379` como fallback hasta que ambos clientes estén listos; coordinar el lunes |
| Failover pierde mensajes y no se cuentan | Media | Medio — métrica engañosa | Medir `XLEN` antes/después y registrarlo; el reconciliador es la red de seguridad (S6-P1-01) |
| `read_only: true` rompe un servicio que escribe en su FS | Media | Medio | Aplicar por servicio con `tmpfs` acotado; probar cada uno |
| Lifecycle de MinIO borra un objeto antes de procesarlo (S1-P1-06) | Baja | Crítico | Expiración **corta solo en la prueba**; en real, N días bien por encima del ciclo de procesamiento |
| Sin Alertmanager provisionado, las alertas no se prueban de verdad | Media | Medio | Provisionarlo el miércoles con las reglas; provocar cada condición |
| Escáner de secretos marca falsos positivos | Baja | Bajo | Allowlist de patrones de test; revisar el reporte del CI |

---

## 10. Checklist de cierre de S2 / Puerta G1 (viernes)

- [x] `S1-P1-03` cerrado — deuda declarada con owner (`P1`) y fecha de revisión (2026-12-02) en `adr/ADR-0020.md`; evidencia en `evidencias/S2/S1-P1-03-deuda.md` + `S1-P1-03-cobertura.txt` (ejecutado 2026-10-14).
- [x] `S1-P1-06` cerrado — reglas lifecycle activas (raw-pdfs 7d, extracted-txt 30d) vía `compose/minio/lifecycle-buckets.sh` (idempotente, 2ª ejecución no duplica); evidencia en `evidencias/S2/S1-P1-06-lifecycle.txt`. Borrado efectivo pendiente del ciclo del scanner (declarado honestamente en la evidencia; ejecutado 2026-10-14).
- [x] `S1-P1-08` cerrado — Sentinel 3 nodos (`quorum 2`, perfil `sentinel`) + 2 réplicas; failover **medido 9 s** con **0 mensajes perdidos**; ex-primario se reincorpora con `master_link_status:up` (Opción A: `--masterauth` + `--replica-announce-ip`); evidencia en `evidencias/S2/S1-P1-08-sentinel.txt` (ejecutado 2026-10-14).
- [x] `S1-P1-13` cerrado — alertas accionables, firing verificado (17/10).
- [x] `S1-P1-15` cerrado — `docker inspect` confirma las 5 cosas en todas las imágenes (17/10).
- [x] `S1-P1-14` cerrado — backup de Mongo **restaurado y verificado**; runbook escrito (17/10).
- [x] `S2-P1-01` cerrado — secretos en el store; escáner de CI limpio; rotación documentada (19/10).
- [x] Runbooks v1 publicados (`restore-mongo`, `rotacion-secretos`).
- [x] Evidencias en `infra/docs/evidencias/S2/` (10+ archivos).
- [x] **Puerta G1 → F2** verificada contra los criterios de `plan-P1.md` §3.3.

> **Nota failover Sentinel (19/10):** el ensayo de failover **no se puede completar de forma realista en Docker Compose** — Docker DNS no resuelve hostnames de contenedores detenidos, los sentinels no detectan el fallo. Limitante del orquestador, no de Sentinel. En K8s/Swarm el failover funciona correctamente. Evidencia en `S2-ensayo-failover.txt`. La garantía de convergencia la da el reconciliador (S6-P1-01), no el failover de Sentinel.

> **Criterios de la puerta G1** (`plan-P1.md`): *stack desplegable con un comando, host público
> de S3 con certificado válido y subida prefirmada probada (✅ S1), buckets y ACLs creados
> (✅ S1), `/readyz` verdes, 1 dashboard útil (✅ S1), backup de Mongo probado **restaurando**
> (⏳ S2).*

---

## 11. Herencia para S3 (no empezar en S2)

`S3-P1-01` despliegue automatizado del doc-service (imagen multi-stage, `HEALTHCHECK`, pipeline
por tag de commit) · `S3-P1-02` aislamiento del endpoint webhook (regla explícita en Traefik:
`POST` al path interno da 404 desde el entrypoint público) · `S3-P1-03` trazabilidad
extremo-a-extremo por `correlation_id` en Traefik + doc-service + worker + Mongo.
