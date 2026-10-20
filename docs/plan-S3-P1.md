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

**Riesgo:** item 3 (contracts others consume — se restringe acceso a path interno).

El path `/internal/storage/events` **no debe ser accesible desde internet**. La protección es doble:
1. **Red**: MinIO está en `infra_data` (sin egress), doc-service en `infra_internal` + `infra_data`.
2. **Traefik**: regla explícita que **no** enruta `/internal/*` desde el entrypoint público.

En `infra/traefik/dynamic/`, añadir un router de **denegación** para paths internos:

```yaml
http:
  routers:
    # ... existentes ...
    block-internal:
      rule: "Host(`api.localhost`) && PathPrefix(`/internal/`)"
      entryPoints: [websecure]
      middlewares: [reject-internal]
      service: noop@internal

  middlewares:
    reject-internal:
      headers:
        customResponseHeaders:
          X-Content-Type-Options: nosniff
      # Respuesta 404 sin revelar existencia
      errors:
        status: ["404"]
        service: noop@internal
        query: "/{path}"
```

Alternativa más simple (sin errors): usar un middleware `replacePath` que redirija a un backend inexistente, o simplemente **no definir router para `/internal/*`** — Traefik por defecto retorna 404 para paths sin router.

Verificación:
```bash
# Desde internet (externo):
curl -sk -o /dev/null -w "%{http_code}" https://api.localhost:8543/internal/storage/events
# → 404

# Desde red interna (doc-service → MinIO):
docker exec infra-minio-1 curl -sf -X POST \
  -H "Authorization: Bearer $MINIO_WEBHOOK_SECRET" \
  http://doc-service:8080/internal/storage/events \
  -d '{"test": true}'
# → 200
```

**DoD:**
* `curl` externo al path interno da 404.
* MinIO (red `data`) puede POSTear al webhook.
* El webhook valida el token compartido.

**Rollback:** eliminar el router `block-internal` del file provider.

**Evidencia:** `evidencias/S3/S3-P1-02-webhook-aislamiento.txt`.

---

### `S3-P1-03` — Trazabilidad por `correlation_id` (vie 23/10)

**Riesgo:** item 3 (contracts others consume — header HTTP).

El `correlation_id` debe:
1. Generarse en Traefik si no viene del cliente.
2. Propagarse como header HTTP `X-Correlation-Id` a doc-service.
3. Inyectarse en el mensaje de Redis Streams.
4. Persistirse en Mongo (`documents.correlation_id`).

#### Paso 1 — Traefik: middleware para generar/propagar

En `infra/traefik/dynamic/`:

```yaml
http:
  middlewares:
    correlation-id:
      headers:
        customRequestHeaders:
          X-Correlation-Id: ""  # placeholder, se genera con plugin o se confía en el cliente
```

Para generación real se necesita un plugin (Yaegi) o ForwardAuth. Alternativa pragmática: **el cliente siempre envía `X-Correlation-Id`**, y doc-service lo valida/propaga. Si no viene, doc-service lo genera.

#### Paso 2 — doc-service: leer/generar correlation_id

En `doc-service/internal/api/middleware.go` (o equivalente):

```go
func CorrelationID() gin.HandlerFunc {
    return func(c *gin.Context) {
        cid := c.GetHeader("X-Correlation-Id")
        if cid == "" {
            cid = uuid.NewString()
        }
        c.Set("correlation_id", cid)
        c.Header("X-Correlation-Id", cid)
        c.Next()
    }
}
```

#### Paso 3 — Redis Streams: incluir correlation_id en el mensaje

En el relay de Change Streams → Redis:

```go
XADD stream:pdf-processing * document_id <id> object_key <key> correlation_id <cid> schema_version 1
```

#### Paso 4 — Mongo: persistir correlation_id

En el documento:

```go
type Document struct {
    ID            string    `bson:"_id"`
    Status        string    `bson:"status"`
    CorrelationID string    `bson:"correlation_id"`
    CreatedAt     time.Time `bson:"created_at"`
    UpdatedAt     time.Time `bson:"updated_at"`
}
```

#### Paso 5 — Worker: propagar correlation_id en logs

El worker lee `correlation_id` del mensaje Redis y lo usa en logs JSON.

**Verificación E2E:**
```bash
# 1. Crear documento con correlation_id
CORR="corr-e2e-$(date +%s)"
curl -sk -X POST https://api.localhost:8543/api/v2/documents \
  -H "Content-Type: application/json" \
  -H "X-Correlation-Id: $CORR" \
  -d '{"filename": "test.pdf", "size": 1024}'

# 2. Verificar en Mongo
docker exec infra-mongo-1 mongosh -u "$MONGO_ROOT_USER" -p "$(cat secrets/mongo_root_password.txt)" \
  --authenticationDatabase admin --quiet --eval \
  "db.getSiblingDB('documents').documents.find({correlation_id: '$CORR'}, {status:1, _id:1})"

# 3. Verificar en Redis
docker exec infra-redis-streams-1 redis-cli -a "$REDIS_PASS" --no-auth-warning \
  XRANGE stream:pdf-processing - + | grep "$CORR"

# 4. Verificar en logs del worker
docker logs infra-extraction-worker-1 2>&1 | grep "$CORR" | tail -3
```

**DoD:**
* Un `correlation_id` enviado por el cliente aparece en Mongo, Redis y logs del worker.
* Si el cliente no lo envía, el sistema genera uno y lo propaga.
* Búsqueda por `correlation_id` en Mongo devuelve el documento completo.

**Rollback:** revertir middleware y cambios en relay/worker.

**Evidencia:** `evidencias/S3/S3-P1-03-trazabilidad.txt`.

---

## 5. Señales de verificación de la semana

| Horizonte | Señal | Cómo medirla |
|---|---|---|
| Inmediata | CI verde tras cada push | badge en repo |
| Corta | Webhook aislado (404 desde internet) | curl externo |
| Media | `correlation_id` rastreado en 3 componentes | búsqueda cruzada |
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
