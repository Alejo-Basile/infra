# Plan de Ejecución — Semana 3, P1 (Platform / DevOps / SRE)

> **Documento de ejecución semanal.** Deriva de `plan-S2-P1.md` §11 ("Herencia para S3"),
> `SPEC.md` §10 (Observabilidad) y `plan-P1.md` §3.3. S2 cerró la Fase 1 endurecida
> (Sentinel, alertas, backups, secretos). S3 inicia la **Fase 2**: despliegue automatizado
> del Document Management Service.

| Campo | Valor |
|---|---|
| Semana | S3 (Fase 2 — Document Management Service) |
| Fechas | lun 2026-10-19 → vie 2026-10-23 |
| Owner | P1 |
| Pair obligatorio | **Vie** — verificación E2E del pipeline (build → push → deploy → smoke) |
| Hito de cierre | Pipeline por tag de commit verde; imagen corriendo en local via compose |
| Entorno | **Local / académico** (ADR-0016: `api.localhost`, HTTP 8088 / HTTPS 8543) |

---

## 1. Punto de partida: qué dejó S2 y qué se hereda

S2 cerró con la Fase 1 completa. Lo que S3 **no rehace** y lo que hereda:

| Tarea | Estado al cierre de S2 | Trabajo restante en S3 |
|---|---|---|
| `S1-P1-01` Traefik + TLS | ✅ HECHO | Ninguno |
| `S1-P1-04/05` Buckets + identidades | ✅ HECHO | Ninguno |
| `S1-P1-07` Redis AOF | ✅ HECHO | Ninguno |
| `S1-P1-09/10` Mongo RS + usuarios | ✅ HECHO | Ninguno |
| `S1-P1-12` Observabilidad | ✅ PARCIAL aceptado | `S3-P1-03` (trazabilidad) |
| `S1-P1-13` Alertas accionables | ✅ CERRADO | Ninguno |
| `S1-P1-15` Hardening contenedores | ✅ CERRADO | Ninguno |
| `S1-P1-14` Backups restaurando | ✅ CERRADO | Ninguno |
| `S2-P1-01` Secretos + rotación | ✅ CERRADO | Ninguno |

### 1.1 Herencia explícita (de `plan-S2-P1.md` §11)

| ID | Tarea | Prio | Depende de |
|---|---|---|---|
| `S3-P1-01` | Despliegue automatizado del doc-service | P0 | `S1-P1-15` (HEALTHCHECK ya en Dockerfile) |
| `S3-P1-02` | Aislamiento del endpoint webhook | P0 | `S1-P1-03` (deuda mTLS), `S3-P1-01` |
| `S3-P1-03` | Trazabilidad por `correlation_id` | P0 | `S3-P1-01`, `S1-P1-12` |

### 1.2 Estado inicial del doc-service (verificado en código, 2026-10-20)

- **Dockerfile** (`doc-service/Dockerfile`): multi-stage, usuario no-root (UID 10001),
  `HEALTHCHECK` con `wget` cada 10s. **Ya cumple S1-P1-15.** Declaraba
  `ENTRYPOINT ["/usr/local/bin/api"]`; como compose lo envuelve con
  `/entrypoint.sh` y este termina en `exec "$@"`, el contenedor salía con exit 0
  (sin `CMD`). Se corrigió a `CMD`.
- **GitHub Actions** (`doc-service/.github/workflows/`): `ci.yml` existía pero solo
  corría `go vet` y `gofmt`, con guards obsoletos `hashFiles('go.mod')`;
  `gitleaks.yml` ya existía. **No había workflow de release/publicación.**
- **Compose** (`infra/compose/docker-compose.yml`): `doc-service` se construía
  localmente (`build.context: ${DOC_SERVICE_BUILD_CONTEXT:-../../doc-service}`) con
  `image: doc-service:latest`; no había pull desde GHCR ni tag de versión.
- **Tests**: `go vet` limpio; los paquetes herméticos pasan; `go test ./...` cuelga
  porque los tests de `internal/adapters/{mongo,changestream,relay}` requieren Mongo
  RS `rs0` y Redis reales y no tienen skip.
- **Health endpoints**: `/healthz` (liveness), `/readyz` (readiness), `/metrics`
  (Prometheus), verificados en `doc-service/cmd/api/main.go`.
- **Config**: `doc-service/internal/config/config.go` valida variables de entorno;
  los secretos llegan por `/run/secrets/` y el wrapper los exporta.

---

## 2. Objetivo de la semana

Que el doc-service pase de "se construye a mano en local" a **pipeline automatizado por
tag de commit**: cada push a `main` produce una imagen versionada, y un `docker compose
pull && up -d` la despliega de forma reproducible. Esto es la base para que P2/P3
desarrollen contra un contrato estable y para que el cutover (Fase 5) tenga un camino
de release probado.

---

## 3. Calendario día a día

| Día | Foco | Tareas | Hito |
|---|---|---|---|
| Lun 19/10 | Workflow base | `S3-P1-01` parte 1: lint + test en CI | CI verde en cada push |
| Mar 20/10 | Build + push | `S3-P1-01` parte 2: build multi-arch + push GHCR | Imagen publicada por tag |
| Mié 21/10 | Compose pull + deploy | `S3-P1-01` parte 3: compose usa imagen; smoke test | `docker compose up` reproducible |
| Jue 22/10 | Aislamiento webhook | `S3-P1-02`: regla en Traefik | Path interno da 404 desde internet |
| Vie 23/10 | Correlación + cierre | `S3-P1-03`: `correlation_id` E2E | Un ID rastreado en 3 componentes |

---

## 4. Detalle de tareas (pasos, DoD, rollback, evidencia)

### `S3-P1-01` — Despliegue automatizado del doc-service (lun–mié)

**Riesgo:** item 5 (environment — pipeline de release).

**Estado: implementado, verificado localmente y en CI remoto (2026-10-20).**
Ramas pusheadas y PRs abiertas contra `main` (doc-service #38, infra #26) sin
tocar `main`; CI de #38 verde (lint, unit, integration, gitleaks). El release a
GHCR queda pendiente del merge de #38 o de un tag `v*` (decisión humana).

#### Parte 1 — Lint + test en CI

`.github/workflows/ci.yml` (existía solo con vet/gofmt y guards obsoletos
`hashFiles('go.mod')`; se reescribió):

- `lint`: `go vet ./...` + `gofmt -l .` (falla si hay archivos sin formatear).
- `unit`: tests herméticos con
  `PKGS=$(go list ./... | grep -vE 'internal/adapters/(mongo|changestream|relay|redis)$')`
  y `go test -race -count=1 $PKGS`. No se usa `go test ./...`: los tests de
  integración no tienen skip y cuelgan sin servicios.
- `integration`: servicios `mongo:7` (single-node RS `rs0` con
  `rs.initiate({host:"localhost:27017"})`) y `redis:7-alpine`; corre
  `./internal/adapters/{mongo,changestream,relay,redis}/...` con
  `MONGO_TEST_URI=mongodb://127.0.0.1:27017/?replicaSet=rs0` y
  `REDIS_TEST_ADDR=127.0.0.1:6379`.

`gitleaks.yml` no se modifica (el escaneo de secretos ya existía).

**Verificación local (real):**

```bash
go vet ./...                        # OK
$(go env GOROOT)/bin/gofmt -l .     # vacío
PKGS=$(go list ./... | grep -vE 'internal/adapters/(mongo|changestream|relay|redis)$')
go test -race -count=1 $PKGS        # ok en api, config, domain, pdfsvc, reconciler, transport/http, webhook
```

La suite de integración se corrió contra Mongo RS + Redis efímeros con los
mismos comandos del CI (ver evidencia): los 4 paquetes `ok`.

#### Parte 2 — Build multi-arch + push a GHCR

`.github/workflows/release.yml` (nuevo):

- Disparadores: push a `main` y tags `v*`.
- `permissions: contents: read, packages: write`; concurrencia por ref.
- `IMAGE_NAME=ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/doc-service` (minúsculas).
- QEMU + Buildx; login con `GITHUB_TOKEN`; metadata-action con `sha-<short>`,
  semver (`{{version}}`, `{{major}}.{{minor}}`) y `latest` solo en la rama por
  defecto.
- `build-push-action@v6` para `linux/amd64,linux/arm64`, cache GHA,
  `provenance: true` y `sbom: true`.
- Trivy `0.28.0` sobre `IMAGE@digest`, `CRITICAL,HIGH`, `ignore-unfixed`,
  `exit-code: 1`.

**Pendiente (humano):** mergear la PR para que `release.yml` publique la imagen
(o pushear un tag `v*`), y definir la visibilidad del paquete GHCR para que
`docker compose pull` funcione.

#### Parte 3 — Compose por imagen + deploy + smoke

- `compose/docker-compose.yml`: `doc-service` usa
  `image: ${DOC_SERVICE_IMAGE:-ghcr.io/alejo-basile/doc-service}:${DOC_SERVICE_TAG:-latest}`,
  sin `build:`, y `command: ["/usr/local/bin/api"]`.
- `compose/docker-compose.build.yml` (nuevo): override de desarrollo con
  `image: doc-service:local` + `build.context`.
- `compose/doc-service/entrypoint.sh`: corregidos los nombres de entorno que
  espera la app (`MINIO_ACCESS_KEY`, `MINIO_SECRET_KEY`, `REDIS_PASSWORD`);
  antes exportaba `SVC_DOCSERVICE_*` / `REDIS_STREAMS_PASSWORD` y el contenedor
  no arrancaba.
- `scripts/deploy-doc-service.sh <tag>`: `pull`, `up -d --no-build`, espera
  `healthy`, exige `GET https://api.localhost:8543/healthz` = 200 e imprime el
  digest. Rollback = ejecutar con el tag anterior.

**Verificación local (real):**

```bash
DOC_SERVICE_TAG=local docker compose -f compose/docker-compose.yml \
  --env-file .env --profile full up -d --no-build --force-recreate doc-service
# health: healthy; /healthz por Traefik: 200; /api/v2/documents: 200

docker compose -f compose/docker-compose.yml -f compose/docker-compose.build.yml \
  --env-file .env --profile full up -d --build doc-service
# image doc-service:local; healthy; /healthz 200
```

**DoD:**
* `ci.yml` cubre lint, unit e integración; `release.yml` publica multi-arch en GHCR.
* Compose despliega por imagen publicada; el build local queda en el override.
* Deploy reproducible con smoke E2E por Traefik; rollback por tag.

**Evidencia:** `docs/evidencias/S3/S3-P1-01-pipeline.txt`.

**Hallazgos de estado local (reparados para el smoke, fuera de git):**
- `.env` tenía `MONGO_INITDB_ROOT_PASSWORD` / `MONGO_APP_PASSWORD` /
  `MONGO_WORKER_PASSWORD` desincronizados con `secrets/` tras la rotación de S2;
  se alinearon con los secretos y se re-ejecutó `mongo-init` (los usuarios de
  aplicación no existían en el volumen).
- `infra-redis-streams-1` había perdido el alias `redis-streams` en
  `infra_data`; se recreó por Compose y el DNS interno volvió a resolver.
- Sentinel 1/2/3 siguen en `Restarting` (deuda de S2, fuera de alcance).

---

### `S3-P1-02` — Aislamiento del endpoint webhook (jue 22/10)

### `S3-P1-02` — Aislamiento del endpoint webhook (jue 22/10)

**Estado: implementado, verificado localmente y mergeado a main (2026-10-21).**
Commit `67c0f7f` (regla Traefik) y evidencia en
`docs/evidencias/S3/S3-P1-02-webhook-aislamiento.txt`. PR #27 mergeado a main.

**Riesgo:** item 3 (contracts others consume — se restringe el acceso a un path interno).

**Objetivo:** que `/internal/*` no sea alcanzable desde el entrypoint público
(`websecure`). El webhook real es `/internal/storage/events` y solo debe circular
MinIO → doc-service por la red `data` (SPEC §5.2 y §9).

**Riesgo:** item 3 (contracts others consume — se restringe el acceso a un path interno).

**Objetivo:** que `/internal/*` no sea alcanzable desde el entrypoint público
(`websecure`). El webhook real es `/internal/storage/events` y solo debe circular
MinIO → doc-service por la red `data` (SPEC §5.2 y §9).
**Hallazgo de estado actual (2026-10-20):** el POST externo a
`https://api.localhost:8543/internal/storage/events` devuelve 404, pero el access
log de Traefik registra `RouterName: legacy@docker`, `ServiceName: legacy@docker`,
`OriginStatus: 404`. El 404 lo genera el monolito por su catch-all
`Host(`api.localhost`)`, no Traefik: el request atraviesa el gateway y llega al
backend. Ese es el bug a corregir.

**Cambio exacto (una línea, en las labels Docker del monolito en
`compose/docker-compose.yml`):**

```yaml
- "traefik.http.routers.legacy.rule=Host(`api.localhost`) && !PathPrefix(`/internal/`) && !Path(`/internal`)"
```

Se niega el prefijo interno en el **único** catch-all público. Sin router que
matchee, Traefik responde su 404 por defecto antes de elegir backend: el request
no llega al monolito ni a doc-service. Los routers `docv2` (`/api/v2`) y
`docv2health` (`/healthz`) no se modifican.

El handler de doc-service ya valida el token compartido del webhook; este cambio
**no toca código de aplicación**. La negación en el gateway es la capa de red y
el token sigue vigente como defensa en profundidad.

**Por qué NO usar `noop@internal` + `errors`:** `noop@internal` responde
HTTP 418 (`StatusTeapot`), no 404; un middleware `errors` con
`status: ["404"]` no intercepta un 418. El cliente vería 418 y el control no
cumpliría el objetivo. Descartado.

**Por qué NO usar `ipAllowList`:** responde 403 y acopla la regla a la IPAM de
Docker (rango de `infra_internal` / `infra_data`), frágil ante cambios de red.
La negación por path no necesita conocer IPs.

**Por qué NO agregar un router dinámico:** `traefik/dynamic/` solo declara el
router S3; el catch-all legacy vive en labels Docker. Un router de denegación
duplicaría la regla y competiría por prioridad con `legacy`. La negación en el
origen mantiene una sola fuente de verdad.

**Pre-flight (estado local, NO cambios de repo):**
- `.env` tiene `MINIO_WEBHOOK_SECRET` e `INTERNAL_TOKEN` desalineados con
  `secrets/`.
- `minio-notify-init` está en `Created` y `minio-init` salió 1 porque los scripts
  esperan env vars planas mientras compose pasa `*_FILE`.
- Son prerequisitos/follow-ups para el E2E real y **no** quedan resueltos por este
  cambio.
- Si no se puede confirmar el target/evento de MinIO, el POST sintético interno
  (fila 6) igual prueba el handler y el token.

**Matriz de verificación:**

| # | Comando / evidencia | Esperado |
|---|---|---|
| 1 | `docker compose -f compose/docker-compose.yml --env-file .env --profile full config -q` | exit 0 |
| 2 | `curl -sk -o /dev/null -w "%{http_code}" -X POST https://api.localhost:8543/internal/storage/events -H 'Content-Type: application/json' -d '{}'` | `404` |
| 3 | Igual que (2) con `-H "Authorization: Bearer $(cat secrets/minio_webhook_secret.txt)"` | `404` (el gateway bloquea antes del handler; si llegara, sería 200/401) |
| 4 | `curl -sk -o /dev/null -w "%{http_code}" -X POST https://api.localhost:8543/internal/documents/x/uploaded` | `404` |
| 5 | Access log de Traefik tras el cambio | sin `legacy@docker`; `DownstreamStatus: 404`; `OriginStatus: 0` o ausente (contrastar con la línea "before") |
| 6 | Desde el contenedor MinIO: `curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' http://doc-service:8080/internal/storage/events` | `200` con token válido; `401` con `Bearer wrong` |
| 7 | `docker port infra-doc-service-1` | vacío (sin puertos publicados) |
| 8 | `docker network inspect infra_data --format '{{.Internal}}'` | `true` |
| 9 | Regresiones: `/healthz`, `/api/v2/documents`, `s3.localhost` health | `200` / `200` / `200` |

**DoD:** las filas 1–9 se cumplen; el path interno solo responde por la red
`data` y el token compartido se valida en el handler.

**Rollback:** quitar la negación de la regla `legacy` y recrear el monolito. El
path vuelve al 404 actual del monolito; no hay cambios de datos.

**Evidencia:** `docs/evidencias/S3/S3-P1-02-webhook-aislamiento.txt`.

---

### `S3-P1-03` — Trazabilidad por `correlation_id` (vie 23/10)

**Riesgo:** item 3 (contracts others consume — header HTTP).

**Estado: implementado y verificado localmente (2026-10-20).**
Alcance A: el E2E real del worker queda diferido a `S4-P1-01`; aquí se
verifica el contrato del mensaje, no un consumer inexistente. Commits:
doc-service `feat/s3-p1-03-correlation-id` (stacked sobre
`feat/s3-p1-01-doc-service-pipeline`, `48b02f0`): `f78c00b` (validación y
normalización del header), `0f03a4f` (propagación en transiciones del
webhook), `eb54d7a` (contrato Redis). infra `feat/s3-p1-03-correlation-id`
(stacked sobre `feat/s3-p1-02-webhook-isolation`, `e78b56a`): `6359133` (fix
de suscripción del target webhook en los jobs init), `ab5f124` (E2E
`scripts/e2e-correlation.sh`).

**Qué se construyó (reemplaza los bocetos previos, que estaban desactualizados):**

- **Traefik NO genera UUIDs** (no existe middleware nativo para ello en OSS).
  doc-service genera el `correlation_id` en el primer request sin header
  válido (SPEC §10). `traefik.yml` conserva `X-Correlation-Id: keep` en el
  access log, que solo preserva un valor inbound. Sin plugins, ForwardAuth ni
  middlewares nuevos en S3.
- **Header normalizado en doc-service** (`f78c00b`): constante Go
  `X-Correlation-ID` (los headers HTTP son case-insensitive), TrimSpace, máx
  128 caracteres, charset `^[A-Za-z0-9._:-]+$`; si falta o es inválido genera
  UUID v4 y lo devuelve en el response header. El warning solo loguea el
  largo del valor crudo, nunca su contenido.
- **Webhook con historial** (`0f03a4f`): el endpoint real es
  `/internal/storage/events` (la mención de SPEC §9 a
  `/internal/documents/{id}/uploaded` está desactualizada). Carga el documento
  antes de leer MinIO; documento inexistente o no `PENDING_UPLOAD` responde
  `200 no_transition` sin I/O de objetos; las transiciones usan
  `UpdateStatusWithHistory` con actor `minio-webhook`, el `correlation_id` del
  documento (fallback al del request) y reason `NOT_A_PDF` al rechazar.
- **Contrato Redis fijado** (`eb54d7a`): la entrada del stream tiene
  exactamente un campo `payload` (JSON) con exactamente `document_id`,
  `object_key`, `correlation_id`, `enqueued_at`, `schema_version`; sin
  `attempts` (el delivery count vive en XPENDING, SPEC §5.4). Discrepancia
  conocida: SPEC §5.4 muestra un XADD plano; el envelope `payload` se conserva
  y la alineación de SPEC queda como follow-up documental.
- **Persistencia en Mongo**: `documents.correlation_id` + historial por
  transición.
- **Logs del worker**: diferidos a `S4-P1-01` (no hay consumer desplegado).

**Hallazgo 401 y fix del target de notificación (`6359133`, breve):** la
primera corrida del E2E falló porque el evento del bucket estaba suscrito al
target gestionado por `mc`, cuya config persistida no tenía `auth_token`
aplicado al proceso (`mc admin config set` escribe el config store pero MinIO
solo aplica notificaciones al reiniciar, y la verificación vieja grepeaba solo
`endpoint=`). El target declarado por env en compose (`DOCSERVICE`, token
correcto, aplicado en cada arranque) existía sin suscripción. El fix hace que
`init-notifications.sh` verifique el target `DOCSERVICE`, retire la
suscripción legacy de mc si existe (idempotente, probado en vivo) y suscriba
`ObjectCreated:Put` a él; ambos scripts init ganaron `resolve_secret` (soporta
`*_FILE`, falla en vacío, nunca imprime secretos).

**Matriz de verificación (resultados reales):**

| # | Comando / evidencia | Resultado |
|---|---|---|
| 1 | `go test ./internal/transport/http ./internal/webhook -race -count=1` (doc-service) | ok (1.662s / 1.066s) |
| 2 | `go vet ./...` + `gofmt -l .` (doc-service) | limpio / vacío |
| 3 | Suite hermética `go test -race -count=1 $PKGS` (excluye adapters mongo/changestream/relay/redis) | ok en api, config, domain, pdfsvc, reconciler, transport/http, webhook |
| 4 | Integración con Mongo RS efímero (27018) + Redis efímero (6380): `go test ./internal/adapters/redis ./internal/adapters/relay -race -count=1 -v` | PASS, incl. `TestWorkQueue_PayloadDelContrato` (decode estricto del payload) |
| 5 | `bash -n` en init-buckets.sh, init-notifications.sh, e2e-correlation.sh | OK |
| 6 | `docker compose -f compose/docker-compose.yml --env-file .env --profile full config -q` | exit 0 |
| 7 | `docker compose ... run --rm minio-init` | exit 0 (buckets, políticas, usuarios) |
| 8 | `docker compose ... run --rm minio-notify-init` | suscripción legacy retirada; solo `DOCSERVICE` suscrito; re-corrida idempotente ("Evento ya suscrito") |
| 9 | `./scripts/e2e-correlation.sh` | ALL OK, exit 0 (salida completa en la evidencia) |

**DoD:**
* Un `correlation_id` enviado por el cliente aparece en Traefik, doc-service,
  Mongo y Redis: ✅ verificado por el E2E (pasos 1–5).
* Si el cliente no lo envía (o envía uno inválido), doc-service genera UUID v4
  y el valor crudo no aparece ni en responses ni en logs: ✅ verificado
  (pasos 7–8 del E2E).
* Búsqueda por `correlation_id` en Mongo devuelve el documento completo: ✅
  cerrado con la consulta post-E2E
  `db.documents.findOne({correlation_id:"corr-s3p103-20261020T210202Z"})` →
  `{_id: "c9e69df7ac94fdaa129581f376503668", status: "UPLOADED", history_len: 2}`.

**Revisión nativa (RDD):** los dos slices pasaron el review nativo (consent:
"Revisar este cambio") y quedaron aprobados con la autoridad quemada:
doc-service `review-db63df1eef2e3118` (lentes risk + reliability) e infra
`review-e0fc16f82f05af69` (lentes risk + resilience). 8 advisories, 0
BLOCKER/CRITICAL (detalle en la evidencia, sección 9). Follow-ups: credenciales
del E2E expuestas en argv, chequeo de presencia del `auth_token` en el job y
robustez del patrón de chequeo de endpoint.

**Rollback:** revertir los cinco commits de código en ambos repos (tres en
doc-service, dos en infra). El job `minio-notify-init` es idempotente: al
volver al script anterior, la suscripción se puede re-crear sin estado
residual. No hay cambios de datos que revertir.

**Evidencia:** `docs/evidencias/S3/S3-P1-03-trazabilidad.txt`.

---

## 5. Señales de verificación de la semana

| Horizonte | Señal | Cómo medirla |
|---|---|---|
| Inmediata | CI verde tras cada push | badge en repo |
| Corta | Webhook aislado (404 desde internet) | curl externo |
| Media | `correlation_id` rastreado en 3 componentes | ✅ verificado (2026-10-20): Traefik, doc-service, Mongo y Redis; logs del worker en `S4-P1-01` |
| Cierre | Documento E2E alcanza estado terminal | GET /documents/{id} |

---

## 6. Herencia para S4

* `S4-P1-01` — Worker Rust completo (consumer group, XAUTOCLAIM, Retry + Circuit Breaker, escritura en Mongo)
* `S4-P1-02` — Rate limiting distribuido (ForwardAuth + Redis, Opción B de SPEC §8)
* `S4-P1-03` — Replay de corpus PDF (válidos, inválidos, escaneados, cifrados, grandes)

---

## 7. Qué NO hacer en S3

1. **No desplegar en staging remoto** sin autorización explícita del destino.
2. **No commitear `secrets/`** ni archivos con credenciales.
3. **No romper el aislamiento de red** (`data`/`internal` sin salida a internet).
4. **No usar el middleware nativo RateLimit** de Traefik (no es distribuido).
5. **No dejar el endpoint webhook público** — debe quedar aislado por red y con secreto compartido.
