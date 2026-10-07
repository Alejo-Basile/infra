# Plan de Ejecución — Semana 1, P1 (Platform / DevOps / SRE)

> **Documento de ejecución semanal.** Deriva de `pasos-iniciales.md` (§6.1, §6.3) y `SPEC.md` v2.1.
> Reemplaza al calendario genérico de `pasos-iniciales.md` para S1 **porque el estado real del
> proyecto ya no es el que ese calendario asume**: S0 adelantó infraestructura del lunes al
> jueves, y P2 cerró las fases F1/F2 del doc-service (issues #8–#24). Este plan parte de lo
> que **ya está verificado en runtime** y queda centrado en cerrar DoD pendientes, pruebas de
> fuego y observabilidad.

| Campo | Valor |
|---|---|
| Semana | S1 (Fase 1 — Infraestructura base) |
| Fechas | lun 2026-10-05 → vie 2026-10-09 |
| Owner | P1 |
| Pair obligatorio | **Mié (movido a medio día con P2)** — pools Mongo, `writeConcern: majority`, Change Streams sobre **código real** |
| Hito de cierre | Host S3 verificado con flujo real E2E + evidencias de DoD publicadas |
| Entorno | **Local / académico** (no hay despliegue remoto; ver ADR-0016) |

---

## 1. Contexto: qué cambió respecto al calendario genérico

El plan original de `pasos-iniciales.md` §6.1 asumía que la S1 empieza desde cero ("desplegar
Traefik", "desplegar buckets"...). La verificación en runtime del 05/10 demuestra otra cosa:

| Tarea del plan | Estado real verificado | Trabajo restante en S1 |
|---|---|---|
| `S1-P1-01` Traefik entrypoint único + TLS | **Hecho en S0** (variante local mkcert, ADR-0016). `https://s3.localhost:8543/minio/health/live` → 200; `http` → 301; router `s3-api` solo al 9000. | Solo la evidencia formal y el DoD completo (certs por host + redirect). |
| `S1-P1-04/05` Buckets + identidades MinIO | **Hecho** (`minio/init-buckets.sh` idempotente; policies `docservice-rw` / `worker-extract`; sin listado anónimo). | Test negativo `AccessDenied` + matriz `servicio×bucket×permiso` versionada. |
| `S1-P1-07` Redis AOF / ACL / `noeviction` | **Hecho** (instancias separadas `redis-streams` AOF+noeviction y `redis-ratelimit` LRU; `appendonlydir` confirmado en disco). | **Test formal**: `XADD` sobrevive a `docker restart`. |
| `S1-P1-09/10` Mongo RS `rs0` + usuarios | **Hecho** (`rs.status()` → PRIMARY; rol a medida `documentsUpdater` del ADR-0006: solo `update`+`find` sobre `documents`). | Verificación del `watch()` con evento < 1 s. |
| `S1-P1-11` Índices + TTL con gracia | **Hecho por P2** (migraciones versionadas, issue #10). | P1 **verifica**, no crea: inspección de índices + cálculo documentado de la gracia. |
| `S1-P1-02` Buffering 1 MB | Config hecha (`body-limit-1mb`). Plan decía: queda `EN CURSO` hasta S3 (parte b). | **Cierre completo posible en S1**: P2 ya emite la policy `POST` con `content-length-range` → se puede correr el test `EntityTooLarge` de 30 MB. |
| `S1-P1-16` Exposición S3 por host dedicado | **Hecho** (router declarado, 9001 sin exposición, `mc anonymous get` denegado). | **Prueba de fuego SigV4** con flujo real (DoD de ADR-0016). |
| `S1-P1-12` Observabilidad | Parcial: Prometheus/Loki/Grafana corriendo y provisionados. | Scrape del doc-service real (ya existe) + dashboard "recorrido de un `document_id`". |
| `S1-P1-03` mTLS interno | Opcional (P2), no bloquea puertas. | Decisión y registro como deuda si aplica (S2). |
| `S1-P1-06/08/13/14`, `S2-P1-01` (lifecycle, Sentinel, alertas, backups-restaurando, secretos) | Son **S2** con sus ensayos. | **NO adelantarlos a medias** (ver §8). |

### Adaptación local (vigente toda la semana) — ADR-0016

- Hosts: `api.localhost` (control) y `s3.localhost` (datos). TLS local con **mkcert**
  (`./scripts/gen-certs.sh`), no ACME.
- **Puertos publicados reales: HTTP 8088, HTTPS 8543** (anti-colisión). Todos los comandos y
  DoD de este documento los usan; el plan genérico asume 80/443 y hay que traducirlo siempre.
- El doc-service firma con `MINIO_PUBLIC_ENDPOINT=https://s3.localhost` (`.env`, nunca literal).
- El panel de MinIO (:9001) **no** tiene router en Traefik.

---

## 2. Objetivo de la semana

Cerrar todos los DoD de infraestructura que el calendario ubica en S1, **probando contra el
flujo real del doc-service** (POST → presign → subida directa → webhook → `UPLOADED` en
Mongo), dejando evidencia reproducible de cada verificación, y entregando el primer dashboard
de observabilidad útil. S1 termina con el checkpoint informal de mitad de fase.

---

## 3. Calendario día a día

| Día | Foco | Tareas | Hito |
|---|---|---|---|
| Lun 05/10 | Verificación heredada + identidades MinIO | V-01, V-02, `S1-P1-05a` | Matriz de permisos versionada; test `AccessDenied` en verde |
| Mar 06/10 | Mongo: índices/TTL (verificación) + Redis AOF | `S1-P1-11v`, `S1-P1-07a`, `S1-P1-10v` | TTL con gracia documentado; `XADD` sobrevive a restart |
| Mié 07/10 | Pair P1+P2 + E2E real | `S1-P1-09v`, E2E-01 | `watch()` < 1 s; documento llega a `UPLOADED` por el webhook |
| Jue 08/10 | Pruebas de fuego SigV4 + límites de tamaño | `S1-P1-16a/b/c`, `S1-P1-02a/b` | `SignatureDoesNotMatch` demostrado; `EntityTooLarge` desde MinIO |
| Vie 09/10 | Observabilidad con servicio real + cierre | `S1-P1-12a/b` | Dashboard v1 con recorrido por `document_id`; checkpoint + demo |

---

## 4. Detalle de tareas (pasos, DoD, rollback, evidencia)

Convenciones: se trabaja desde `infra/` salvo que se indique. Guardar la salida de cada
verificación en `infra/docs/evidencias/S1/` (crear el directorio). Cada comando destructivo
lleva su paso de rollback.

### V-01 — Verificación formal de Traefik + TLS (cierra DoD de `S1-P1-01`)

```bash
# 1. Redirect 80→443
curl -s -o /dev/null -w '%{http_code}\n' http://api.localhost:8088/          # esperado: 301
# 2. Cert por host (s3)
curl -skv https://s3.localhost:8543/minio/health/live 2>&1 | grep -E 'subject|issuer'  # CN=s3.localhost, CA mkcert
curl -sk -o /dev/null -w '%{http_code}\n' https://s3.localhost:8543/minio/health/live  # 200
# 3. Cert por host (api) y router legacy del monolito
curl -sk -o /dev/null -w '%{http_code}\n' https://api.localhost:8543/docs      # 200/404 del monolito = router OK
```

- **DoD**: redirect 301; cada host responde con **su** certificado mkcert; el monolito
  responde por `api.localhost` sin puerto publicado propio.
- **Rollback**: ninguno (solo lectura).
- **Evidencia**: `V-01-traefik-tls.txt` (salidas de los 3 comandos).

### V-02 — Healthchecks del stack

```bash
docker compose --profile full ps --format 'table {{.Name}}\t{{.Status}}'
```

- **DoD**: los 9 servicios `infra-*` en `healthy` (o `running` los sin healthcheck).
- **Evidencia**: `V-02-stack-ps.txt`.

### `S1-P1-05a` — Test negativo de identidades MinIO + matriz de permisos (cierra `S1-P1-04/05`)

> **✅ Estado tras ejecución (05/10): FALLÓ primero, CORREGIDO y VERIFICADO.** El test inicial
> reveló `.env` con `SVC_*` == root (root ignora policies) — ver
> `docs/evidencias/S1/S1-P1-05-FALLO-root-collision.txt`. Se regeneraron las credenciales,
> se endureció `init-buckets.sh` (fail-fast si `SVC_*` == root, sin fallback deprecado) y tras
> recrear `minio-init`: usuarios reales con policy adjunta, worker→`raw-pdfs` = **AccessDenied**,
> worker→`extracted-txt` = OK (con limpieza), anónimo = **403** (ver `S1-P1-05-accessdenied.txt`).
> **Nota sobre la imagen mc (Bitnami):** requiere `--entrypoint mc`, si no el entrypoint de
> Bitnami intenta `exec admin` y falla ("exec: admin: not found").

```bash
source .env
# El usuario del WORKER intenta ESCRIBIR en raw-pdfs (prohibido): debe dar AccessDenied
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_w=http://${SVC_WORKER_ACCESS_KEY}:${SVC_WORKER_SECRET_KEY}@minio:9000 \
  bitnamilegacy/minio-client:2025.7.21 cp /etc/hostname w/raw-pdfs/forbidden.txt
```

1. Versionar la matriz en `infra/docs/permisos-minio.md`:

| Identidad | raw-pdfs | extracted-txt |
|---|---|---|
| `SVC_DOCSERVICE` | Get, List, Head, **presign** | Get, List |
| `SVC_WORKER` | Get **(sin Put)** | Get, Put, Delete |
| root | solo operación admin local, nunca en apps | — |

- **DoD**: (a) `mc admin policy info local docservice-rw` y `worker-extract` muestran
  exactamente lo documentado; (b) el `PutObject` del worker en `raw-pdfs` devuelve
  `AccessDenied`; (c) la matriz está commiteada.
- **Rollback**: ninguno (la prueba falla sin escribir nada).
- **Evidencia**: `S1-P1-05-accessdenied.txt`, commit del `.md`.

### `S1-P1-11v` — Verificación de índices y TTL (creados por P2, issue #10)

```bash
docker exec infra-mongo-1 mongosh --quiet \
  -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" --authenticationDatabase documents \
  documents --eval 'db.documents.getIndexes()'
```

1. Confirmar que existen: único `_id`, `status`, `updated_at`, y **TTL sobre `expires_at`**.
2. **Documentar en el runbook** el cálculo real que P2 implementó:
   `expires_at = ventana_de_subida + gracia`, con `gracia ≥ 2 × intervalo_del_reconciliador`
   (reconciliador v1: cada 5–10 min → TTL efectivo no menor a ~25–30 min tras vencer).
3. **Chequeo de riesgo crítico (SPEC §4)**: confirmar con P2 que ningún entorno persiste
   documentos `PENDING_UPLOAD` con `expires_at < gracia` — mientras el reconciliador v1 sea
   solo detección, el TTL es peligroso si la gracia es corta.

- **DoD**: `getIndexes()` muestra los 4 índices; el cálculo de gracia queda escrito en
  `infra/runbooks/mongo-ttl.md`; no hay documentos cuya gracia sea insuficiente.
- **Rollback**: ninguno (verificación). Si falta un índice → bloquear a P2 (es su tarea).
- **Evidencia**: `S1-P1-11-indexes.txt`.

### `S1-P1-07a` — Test formal de persistencia AOF (cierra `S1-P1-07`)

```bash
# 1. Escribir un mensaje de prueba en el stream real
docker exec infra-redis-streams-1 redis-cli -a "$REDIS_STREAMS_PASSWORD" --no-auth-warning \
  XADD stream:pdf-processing '*' document_id test-s1-aof object_key raw-pdfs/test.pdf correlation_id test-s1 schema_version 1
# 2. Reiniciar el contenedor
docker restart infra-redis-streams-1 && sleep 5
# 3. El mensaje sigue ahí
docker exec infra-redis-streams-1 redis-cli -a "$REDIS_STREAMS_PASSWORD" --no-auth-warning \
  XRANGE stream:pdf-processing - + | grep test-s1-aof
```

- **DoD**: tras el restart el `XADD` está presente (AOF `everysec` restauró el stream).
- **Rollback/limpieza**: `XDEL stream:pdf-processing <id>` del mensaje de prueba.
- **Evidencia**: `S1-P1-07-aof-restart.txt`.

### `S1-P1-10v` — Verificación de usuarios Mongo

```bash
# root desde la app NO debe poder escribir en la base del servicio con rol incorrecto;
# y el usuario worker NO puede hacer insert:
docker exec infra-mongo-1 mongosh --quiet \
  -u "$MONGO_WORKER_USER" -p "$MONGO_WORKER_PASSWORD" --authenticationDatabase documents \
  documents --eval 'try { db.documents.insertOne({x:1}) } catch(e){ print("OK insert denegado:", e.codeName) }'
```

- **DoD**: `insert` del worker → denegado (`Unauthorized`); `find`+`update` funcionan;
  conexión con `MONGO_APP_USER` hace CRUD completo.
- **Evidencia**: `S1-P1-10-roles.txt`.

### `S1-P1-09v` — Change Stream emite en < 1 s (sobre RS real)

Con el doc-service levantado (pair del miércoles) o con un `mongosh` manual:

```bash
# Terminal A: watch con filtro del relay
docker exec infra-mongo-1 mongosh --quiet -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" \
  --authenticationDatabase documents documents --eval '
    const cs = db.documents.watch([{$match:{operationType:"update","fullDocument.status":"UPLOADED"}}]);
    const t0 = Date.now();
    if (cs.hasNext()) print("latencia_ms:", Date.now()-t0);'
# Terminal B: provocar el update de un doc de prueba
```

- **DoD**: evento recibido en < 1 s desde el `update` (requiere RS + `readConcern majority`).
- **Evidencia**: `S1-P1-09-changestream.txt`.

### Pair P1+P2 (Mié) — sobre código real

Agenda de 120 min: revisar juntos `S1-P2-01` (pool, timeouts, `writeConcern: majority`) y
`S1-P2-06..08` (watcher, resume token, apagado). Salida: commit con nota de pair +
anotaciones en el PR de P2. **No es revisión de diseño abstracto: es el relay que ya corre.**

### E2E-01 — Flujo real con doc-service (cierra el hito del miércoles)

```bash
# 1. Crear documento (doc-service por Traefik)
curl -sk -X POST https://api.localhost:8543/api/v2/documents \
  -H 'Content-Type: application/json' -d '{"filename":"test.pdf","size_bytes":12345,"content_type":"application/pdf"}'
#  -> {document_id, upload_url, method:"POST", form_fields, required_headers, expires_in}

# 2. Subir el PDF DIRECTO a MinIO por el host S3 (multipart con form_fields)
#    (armar el curl con los campos devueltos; el host DEBE ser s3.localhost:8543)

# 3. Verificar la cadena: webhook -> Mongo -> Change Stream -> XADD + WAIT
docker exec infra-mongo-1 mongosh --quiet ... --eval \
  'printjson(db.documents.findOne({_id:"<document_id>"},{status:1,updated_at:1}))'   # status: UPLOADED
docker exec infra-redis-streams-1 redis-cli -a "$REDIS_STREAMS_PASSWORD" --no-auth-warning \
  XLEN stream:pdf-processing   # +1 mensaje con ese document_id
```

- **DoD**: `PENDING_UPLOAD → UPLOADED` solo tras existir el objeto; mensaje encolado con
  deduplicación (`XLEN` no crece al repetir el webhook).
- **Depende de**: doc-service desplegado en el compose con labels `traefik.enable` y router
  `/api/v2` con prioridad alta (coordinar con P2 el miércoles por la mañana; si no está
  integrado a compose, E2E-01 se corre local con el stack de datos del perfil `core`).
- **Evidencia**: `E2E-01-flujo.txt` (response del POST, estado en Mongo, `XLEN`).

### `S1-P1-16a` — Router S3 solo al puerto 9000 (DoD de exposición)

```bash
# La consola NO debe existir por el entrypoint publico:
curl -sk -o /dev/null -w '%{http_code}\n' https://s3.localhost:8543/minio/   # 404 o health, NUNCA la consola
docker port infra-minio-1                                                     # sin 9001 publicado al host
docker exec infra-traefik-1 wget -qO- http://localhost:8082/api/http/routers 2>/dev/null | grep -c 9001 || echo "9001 sin router: OK"
```

- **DoD**: ningún router de Traefik apunta al 9001; MinIO no publica 9001 al host.
- **Evidencia**: `S1-P1-16-router.txt`.

### `S1-P1-16b` — Prueba de fuego SigV4 (DoD de ADR-0016) — test positivo y negativo

**Positivo** (cubierto por E2E-01): subida firmada contra `https://s3.localhost:8543` funciona.

**Negativo (la demostración pedagógica)**:

```bash
# Temporalmente, pedir a P2 (o forzar en su .env local) MINIO_PUBLIC_ENDPOINT=http://minio:9000
# y repetir E2E-01 paso 2 SIN cambiar nada mas:
#  -> la subida debe fallar con SignatureDoesNotMatch (403), con la API y MinIO sanos.
# Registrar el error y revertir la variable de inmediato.
```

- **DoD**: (a) subida firmada con host correcto → 204/200; (b) misma subida con host
  interno → `SignatureDoesNotMatch`; (c) la variable queda revertida.
- **Rollback**: restaurar `MINIO_PUBLIC_ENDPOINT=https://s3.localhost` y reiniciar doc-service.
- **Evidencia**: `S1-P1-16-sigv4.txt` ← pieza central de la defensa académica.

### `S1-P1-16c` — Listado anónimo deshabilitado

```bash
docker run --rm --network infra_data --entrypoint mc bitnamilegacy/minio-client:2025.7.21 \
  alias set anon http://minio:9000 "" "" --api S3v4 && \
docker run --rm --network infra_data --entrypoint mc bitnamilegacy/minio-client:2025.7.21 \
  ls anon/raw-pdfs     # esperado: AccessDenied
```

### `S1-P1-02a` — Buffering 413 en rutas JSON (DoD parte a)

Requiere que el router del doc-service lleve el middleware `body-limit-1mb` (labels Docker
al integrar E2E-01). Si aún no hay router propio, se valida con un router temporal en
`traefik/dynamic/` apuntando al monolito solo para la prueba:

```bash
head -c 2000000 /dev/zero > /tmp/big.json
curl -sk -o /dev/null -w '%{http_code}\n' -X POST https://api.localhost:8543/api/v2/documents \
  -H 'Content-Type: application/json' --data-binary @/tmp/big.json
docker logs infra-traefik-1 --since 1m | grep '"RequestBodySize"'   # 413 SIN llegar al backend
```

- **DoD**: 413 emitido **por Traefik** (verificable en access log sin upstream).
- **Rollback**: eliminar el router temporal si se usó.

### `S1-P1-02b` — `EntityTooLarge` desde MinIO (DoD parte b, **adelantado** gracias a P2)

```bash
# Generar un "PDF" de 30 MB y pedir la URL prefirmada (la policy fija max 25 MB)
head -c 30000000 /dev/urandom > /tmp/big.pdf
# POST /api/v2/documents declarando 30 MB -> intentar la subida con los form_fields:
#  -> MinIO responde EntityTooLarge (400) y NADA se escribe en raw-pdfs
docker exec infra-minio-1 mc ls local/raw-pdfs 2>/dev/null | wc -l   # sin objeto nuevo
```

- **DoD**: MinIO rechaza con `EntityTooLarge`; el binario nunca atravesó ni Traefik ni
  doc-service (verificar en access log: el 400 viene del router `s3-api`).
- **Con esto `S1-P1-02` pasa de EN CURSO a HECHA en S1** (el plan original la dejaba abierta hasta S3).
- **Evidencia**: `S1-P1-02-entitytoolarge.txt`.

### `S1-P1-12a` — Scrape de Prometheus del doc-service

Agregar job a `compose/prometheus/prometheus.yml`:

```yaml
- job_name: doc-service
  metrics_path: /metrics
  static_configs:
    - targets: ["doc-service:8080"]   # puerto real del servicio cuando se integre
```

```bash
docker compose --profile full up -d prometheus
curl -s http://localhost:9090/api/v1/targets | grep -o '"health":"up"' | wc -l
```

- **DoD**: target `doc-service` en estado `up`; `up{job="doc-service"} == 1` en la UI.
- **Rollback**: `git checkout -- compose/prometheus/prometheus.yml` + recrear el contenedor.

### `S1-P1-12b` — Dashboard v1: recorrido de un `document_id`

Dashboard en Grafana (provisionado o exportado a `compose/grafana/dashboards/`):
1. Panel Loki: query `{service="doc-service"} |= "<document_id>"` → líneas del request,
   webhook, relay.
2. Panel Traefik: access log filtrado por router y status (métricas `:8082`).
3. Panel Redis: `XLEN stream:pdf-processing` (vía redis-exporter si se agrega, o como
   anotación manual en la demo).
4. Panel Mongo/MinIO: básicos (conexiones, disco).

- **DoD**: dado el `document_id` de E2E-01, el dashboard muestra su recorrido completo
  Gateway → doc-service → Mongo → Redis. Exportar el JSON del dashboard al repo.
- **Evidencia**: captura + `dashboard-v1.json`.

---

## 5. Señales de verificación de la semana

| Horizonte | Señal | Cómo medirla |
|---|---|---|
| Inmediata (0–2 min) | Cada comando de verificación devuelve el código esperado (`301`, `200`, `AccessDenied`, `EntityTooLarge`, `SignatureDoesNotMatch` cuando corresponde) | Salidas en `evidencias/S1/` |
| Corta (2–5 min) | El documento de E2E-01 alcanza `UPLOADED` y aparece en el stream; healthchecks verdes tras cada cambio de compose | `findOne`, `XLEN`, `docker compose ps` |
| Media (5–15 min) | Latencia del Change Stream < 1 s; deduplicación del relay (repetir webhook no duplica mensajes); Prometheus con target `up` | pruebas del miércoles |
| Cierre de semana | 12 evidencias publicadas + dashboard v1 + tablero con DoD cerrados | demo del viernes |

---

## 6. Rollback general de la semana

- Todo cambio de configuración se hace por rama `feat/infra-s1-*` → PR → `main`; el rollback
  de cualquier config es `git revert` + `docker compose up -d <servicio>`.
- Único cambio con estado mutable: ninguno en S1 (los tests son aditivos y se limpian con
  `XDEL`/`mc rm` donde aplica). **Los cambios destructivos (lifecycle, rotación de secretos,
  backups) son S2 y aquí no se tocan.**
- Si el stack queda inestable: `docker compose --profile full down && up -d` con la última
  config de `main` (los volúmenes sobreviven; la AOF de Redis y el RS de Mongo se
  re-inicializan solos por los jobs idempotentes `mongo-init`/`minio-init`).

---

## 7. Comunicación

| Momento | Canal | Contenido |
|---|---|---|
| Lun (planning) | Daily + tablero | Estado heredado de S0 publicado (matriz §1); nadie re-hace trabajo hecho |
| Mié mañana | A P2 | Coordinar integración del doc-service en compose para E2E-01 |
| Mié (pair) | Commit compartido | Nota de pair en el PR |
| Jue | Canal del equipo | Resultado de las pruebas SigV4 y `EntityTooLarge` (cierra `S1-P1-02` y ADR-0016) |
| Vie (demo) | Demo + retro | Dashboard v1 con recorrido real + 3 mejoras con owner |

---

## 8. Qué NO hacer en S1 (guardarraíles)

1. **No adelantar S2 a medias**: Sentinel (`S1-P1-08`), lifecycle (`S1-P1-06`), alertas
   (`S1-P1-13`), backups restaurando (`S1-P1-14`) y secret store (`S2-P1-01`) tienen ensayos
   propios en S2. Hacerlos "rápido" sin ensayo es peor que no hacerlos.
2. **mTLS (`S1-P1-03`)**: decisión en S2; si no entra, queda deuda declarada (§19.3 de
   `pasos-iniciales.md`), no se improvisa.
3. **No tocar el router `legacy` del monolito**: no lleva `body-limit-1mb` a propósito
   (el contrato v1 recibe PDFs por el body; ver comentario en compose).
4. **No "arreglar" `noeviction` subiendo memoria si Redis se llena**: la escritura debe
   fallar y alertarse (S2), nunca desalojar mensajes del stream.
5. **No commitear certificados ni `.env` real**: certs en `traefik/certs/` están
   git-ignored; el keyfile de Mongo igual.

---

## 9. Riesgos de la semana

| Riesgo | Prob. | Impacto | Mitigación |
|---|---|---|---|
| SigV4 falla en E2E-01 por host/puerto mal firmado | Media | Bloquea el hito del miércoles | Probar primero a nivel `mc`/MinIO interno; checklist de `MINIO_PUBLIC_ENDPOINT`, host y puerto (`:8543`) en la URL pública |
| TTL activo (migraciones de P2) borra un `PENDING_UPLOAD` cuyo objeto sí se subió, mientras el reconciliador v1 solo detecta | Baja | **Crítico** (SPEC §4: pérdida silenciosa) | `S1-P1-11v`: verificar gracia real; si es insuficiente, bloqueo a P2 el martes, no el viernes |
| doc-service no está integrado a compose el miércoles | Media | E2E-01 se corre en local (perfil `core`) y la integración pasa a jueves | Plan B documentado; no cancela el pair |
| Confusión de puertos (80/443 en docs vs 8088/8543 reales) | Alta | Horas perdidas | Este documento usa siempre los puertos reales; avisar en el daily del lunes |
| Imagen MinIO Bitnami legacy | Baja | Deriva de comportamiento vs oficial | Pin por tag inmutable ya aplicado; nota en README para reemplazo futuro |

---

## 10. Checklist de cierre de S1 (viernes)

- [ ] DoD `S1-P1-01` cerrado (V-01) — Traefik + TLS + redirect, evidencia publicada.
- [ ] DoD `S1-P1-04/05` cerrado — matriz de permisos commiteada + test `AccessDenied`.
- [ ] DoD `S1-P1-07` cerrado — `XADD` sobrevive a `docker restart` (AOF).
- [ ] DoD `S1-P1-09/10` cerrado — `watch()` < 1 s; rol del worker limitado verificado.
- [ ] DoD `S1-P1-11` verificado — índices + gracia TTL documentadas (owner de creación: P2).
- [ ] DoD `S1-P1-02` **cerrado completo** (partes a y b) — adelantado de S3.
- [ ] DoD `S1-P1-16` cerrado + ADR-0016 verificado con demo SigV4 (positivo y negativo).
- [ ] DoD `S1-P1-12` parcial aceptado — scrape del doc-service + dashboard v1 con recorrido por `document_id`.
- [ ] E2E-01 documentado: `PENDING_UPLOAD → UPLOADED` + mensaje deduplicado en el stream.
- [ ] Pair P1+P2 ejecutado con commit compartido.
- [ ] Evidencias en `infra/docs/evidencias/S1/` (12+ archivos).

## 11. Herencia para S2 (no empezar en S1)

`S1-P1-06` lifecycle · `S1-P1-08` Sentinel 3 nodos + ensayo de failover · `S1-P1-13`
alertas accionables provocadas · `S1-P1-14` backups **verificados restaurando** ·
`S1-P1-15` hardening full (`read_only`, auditoría `docker inspect`) · `S2-P1-01` secret
store + rotación documentada · decisión mTLS (`S1-P1-03`) · **puerta G1 el vie 16/10**.
