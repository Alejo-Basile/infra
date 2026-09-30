# Plan de Trabajo Detallado — P1 (Platform / DevOps / SRE) — Semana 0

> **Contexto:** Plan operativo día a día para la Persona 1 en la Semana 0 (28/09 – 02/10), derivado
> del SDD `SPEC.md` **v2.1**, del plan de ejecución `pasos-iniciales.md` **v1.1** y del plan de rol
> `plan-P1.md` **v1.1**.
>
> **Objetivo de la semana (Puerta G0 → F1):** ADRs firmados (incluida la de compatibilidad de
> clientes y la del host de S3), 4 repositorios con CI en verde, línea base del monolito medida y
> todas las toolchains instaladas y verificables. Sin esto, **no se toca producción**.

---

## 1. Rol de P1 en la Semana 0

P1 es el **habilitador** del equipo. Su misión esta semana no es desplegar nada que levantaré en F1,
sino dejar los **cimientos**: repositorios, toolchains versionadas, un Compose de desarrollo que
funciona con un comando, redes aisladas, seguridad de pipeline desde el minuto cero, y — crítico —
la decisión del **hostname público de MinIO** antes de que nadie escriba una línea que firme URLs.

Responsabilidades RACI relevantes en S0: topología de red (**A/R**), pipelines CI/CD (**A/R**),
seguridad de supply chain (**A/R**), secretos (**A/R**).

---

## 2. Reglas que aplican a todas las tareas

- **Definition of Ready:** cada tarea tiene ID, owner (P1), criterio de aceptación verificable y
  dependencias explícitas. Si una dependencia no está `HECHA`, la tarea se marca `BLOQUEADA`.
- **Definition of Done:** código en `main` con CI verde; cambio reversible y documentado; si aplica,
  README/ADR actualizado.
- **Seguridad no negociable desde el día 1:** nada de secretos en repos (solo `.env.example` con
  valores ficticios), usuarios no-root en todos los Dockerfiles, imágenes base con pin por digest.
- **Ramas:** `feat/`, `fix/`, `chore/` con vida ≤ 2 días; `main` protegida; commits convencionales.
- Toda tarea `P0` de este plan que toque el camino crítico de seguridad requiere **revisión de
  al menos dos personas**.

---

## 3. Calendario día a día

| Día | Foco de P1 | Tareas del día | Hito del equipo |
|---|---|---|---|
| **Lun 28/09** | Crear los 4 repos y el esqueleto de ramas | `S0-P1-01` | Repos creados |
| **Mar 29/09** | Toolchains Go, Rust, `mc`, `trivy`, `gitleaks` | `S0-P1-02` | Build en verde en los 2 servicios |
| **Mié 30/09** | Compose v2 de desarrollo (perfiles) + **decisión del hostname público de S3 (DNS + certificado)** | `S0-P1-03`, `S0-P1-05`, `S0-P1-06`, `S0-P1-07` | Línea base publicada (P4) |
| **Jue 01/10** | Escaneo de secretos en pre-commit y CI + **Pair P1+P2: host de S3 y firma SigV4** | `S0-P1-04` + pair | Contrato de mensajes versionado |
| **Vie 02/10** | Runners de CI y caché de dependencias; demo + retro | Cierre y verificación G0 | Demo del esqueleto + retrospectiva |

---

## 4. Detalle de tareas

### `S0-P1-01` — Crear los 4 repositorios y su estructura (P0)

**Día:** Lunes 28/09 · **Depende de:** —

**Qué hacer:**
1. Crear los 4 repositorios: `infra/`, `doc-service/`, `extraction-worker/`, `platform-services/`
   (este último contendrá `rate-limiter/`).
2. Configurar en cada uno:
   - Rama `main` protegida (sin push directo, sin `force push`, PR obligatorio).
   - `CODEOWNERS` (`@P1` para `infra/` y `platform-services/`).
   - `README.md` que diga **qué hace y qué NO hace** este repo (límites de responsabilidad).
   - Licencia, `.gitignore` apropiado al stack, plantilla de PR (con secciones: *qué cambia,
     por qué, cómo se prueba, cómo se revierte*).
   - Workflow de CI mínimo que corre en el primer push (aunque solo haga lint del README).

**Criterio de aceptación (DoD):** cada repo tiene README, licencia, `.gitignore`, plantilla de PR
y CI que corre en verde en el primer push.

---

### `S0-P1-02` — Toolchains documentadas y versionadas (P0)

**Día:** Martes 29/09 · **Depende de:** `S0-P1-01`

**Qué hacer:**
1. Fijar versiones **por escrito y en código**:
   - Go: versión exacta en `go.mod` de `doc-service/`.
   - Rust: canal estable fijado en `rust-toolchain.toml` de `extraction-worker/`.
   - Imágenes de infraestructura por **tag inmutable** (y donde sea crítico, por digest):
     `traefik:v3.x`, `minio/minio:RELEASE.xxxx`, `redis:7.x`, `mongo:6.x/7.x`, `prom/prometheus`,
     `grafana/grafana`, `grafana/loki`.
2. Escribir `scripts/bootstrap.sh` en `infra/` que verifique en la máquina de cada persona:
   Docker + Compose v2, Go, Rust toolchain, `mc` (cliente MinIO), `trivy`, `gitleaks`.
   El script **no instala en silencio**: si falta algo, dice qué falta y cómo se instala.
3. Documentar en `infra/README.md` cómo ejecutar el bootstrap.

**Criterio de aceptación (DoD):** una persona nueva ejecuta `scripts/bootstrap.sh` y queda con
todo instalado; cualquier ausencia produce un mensaje accionable en < 1 min.

---

### `S0-P1-03` — Compose de desarrollo (P0)

**Día:** Miércoles 30/09 · **Depende de:** `S0-P1-01`

**Qué hacer:**
1. Escribir `docker-compose.yml` (Compose v2) en `infra/` con **perfiles**:
   - `core`: MongoDB + Redis + MinIO (el mínimo que P2 y P3 necesitan para integración).
   - `full`: todo lo anterior + Traefik + Prometheus + Grafana (+ Loki).
   - `chaos`: variante con utilidades/opciones para matar procesos (base para los chaos tests y el
     game day de S9).
2. Puertos locales sin colisiones (documentar el mapa de puertos en el README).
3. Volúmenes con nombre para datos (`mongo-data`, `redis-data`, `minio-data`) para que los
   restart no borren estado.
4. **Hardening base declarado ya en este archivo** (aunque el checklist completo es de S2):
   `read_only` donde sea posible, `cap_drop: ALL`, `no-new-privileges`, `user` no-root en los
   servicios propios.

**Criterio de aceptación (DoD):** `docker compose --profile full up` levanta el stack completo en
una sola orden, en **menos de 3 minutos**, sin errores. `docker compose --profile core up` levanta
solo los datos.

---

### `S0-P1-04` — Seguridad del pipeline desde el outset (P0)

**Día:** Jueves 01/10 · **Depende de:** `S0-P1-01`

**Qué hacer:**
1. Configurar **`gitleaks`** (o `trufflehog`) en dos capas:
   - Pre-commit hook instalable vía bootstrap (`scripts/bootstrap.sh` lo registra).
   - Job de CI en los 4 repos que escanea el diff del PR.
2. Establecer las reglas de supply chain para todos los Dockerfiles del proyecto (vale como
   template compartido en `infra/`):
   - Imágenes base con **pin por digest** (`FROM golang:1.xx@sha256:...`).
   - Multi-stage build.
   - Usuario no-root (`USER` explícito, UID no mapeado a 0).
3. **Prueba de fuego:** insertar a propósito un secreto falso (`AKIA...EXAMPLE`) en una rama de
   prueba, verificar que el escáner lo detecta y bloquea el push/PR, y luego revertir.

**Criterio de aceptación (DoD):** el secreto de prueba es detectado por el escáner (evidencia en el
log del pre-commit o del job de CI) y la rama queda revertida.

---

### `S0-P1-05` — Redes y política de base (P0)

**Día:** Miércoles 30/09 (junto al Compose) · **Depende de:** `S0-P1-03`

**Qué hacer:**
1. Definir en el `docker-compose.yml` las tres redes:
   - `edge`: con salida a internet (donde vive Traefik y lo que él expone).
   - `internal`: sin salida a internet (servicios de aplicación).
   - `data`: solo datos, sin salida a internet (Mongo, Redis, MinIO en su tráfico interno; la
     exposición pública de S3 sale solo por el router dedicado de Traefik en F1).
2. Asignar cada servicio a sus redes explícitamente; ningún servicio de datos en `edge`.
3. Documentar la topología con un diagrama simple en `infra/README.md`.

**Verificación:**
```bash
docker network inspect infra_internal  # internal: true o sin gateway a internet
docker network inspect infra_data
# Desde un contenedor de datos, intentar salida debe fallar:
docker compose exec redis ping -c1 8.8.8.8   # esperado: falla / sin ruta
```

**Criterio de aceptación (DoD):** ningún servicio de datos tiene ruta a internet, verificado con
`docker network inspect` y una prueba de conectividad negativa.

---

### `S0-P1-06` — Límites de recursos por defecto (P1)

**Día:** Miércoles 30/09 (junto al Compose) · **Depende de:** `S0-P1-03`

**Qué hacer:**
1. Todo servicio del `docker-compose.yml` nace con `mem_limit`, límite de CPU y `pids_limit`
   definidos (`cpus`, `pids_limit`, `mem_limit` o sintaxis `deploy` según el modo).
2. Los valores de esta semana son **provisionales por defecto razonables**; los límites del worker
   se calibran con la prueba de carga real en `S5-P1-01` (30 % de margen + `ulimit` + timeout duro
   por riesgo R20, PDF hostil).

**Verificación:**
```bash
docker stats --no-stream   # ningún servicio aparece "sin límite"
docker inspect <contenedor> | jq '.[0].HostConfig | {Memory, NanoCpus, PidsLimit}'
```

**Criterio de aceptación (DoD):** `docker stats` no muestra ningún servicio sin límite.

---

### `S0-P1-07` — Decidir el hostname y entrypoint público de MinIO (P0 — la tarea crítica de la semana)

**Día:** Miércoles 30/09 · **Depende de:** `S0-P1-01`
**Bloquea a:** `S1-P1-04` (buckets) y a todo el sistema de URLs prefirmadas.

**Por qué es P0 y ahora:** la firma **SigV4** incluye el *host* en el *canonical request*. Las
mismas claves producen firmas distintas para `api.dominio` y `s3.dominio`. Si el Document Service
(P2) emite una URL prefirmada con un host distinto del que el cliente golpea, **el 100 % de los
uploads falla con `SignatureDoesNotMatch`**, y el síntoma (un 403 con la API perfectamente sana)
no señala al host. En local nadie lo ve (todos firman contra `minio:9000`). Es la única decisión
de infra que **no se puede recuperar después con un stub**, y además fija el `Host` de un router
de Traefik que es caro cambiar cuando ya hay certificados, reglas de ruteo y clientes encima.

**Qué hacer:**
1. Elegir el nombre del host dedicado para S3: **`s3.<dominio>`** (distinto del host de la API,
   `api.<dominio>`). Documentar la decisión como **ADR-0016**: contexto, opciones (mismo host vs.
   host dedicado vs. path-style), decisión y consecuencias.
2. Crear el **registro DNS** y verificar que resuelve (`dig s3.<dominio>`).
3. Si el entorno ACME ya está disponible, emitir/obtener el **certificado de staging** de Let's
   Encrypt para ese host (nunca "cortar en frío": siempre empezar por el endpoint de staging para
   no agotar la cuota de emisión).
4. Prever el router de Traefik del host de S3 (la configuración formal es `S1-P1-16` en semana 1;
   aquí solo se deja decidido, con DNS y cert).
5. Definir la variable de contrato **`MINIO_PUBLIC_ENDPOINT`** que el doc-service usará para firmar
   (valor desde variable de entorno, nunca literal en código).
6. **Pair programming del jueves (P1 + P2):** explicar a P2 qué rompe un desajuste de host y por
   qué el cert va en la semana 0. Salida: commit compartido con nota de pair.

**Criterio de aceptación (DoD):**
- Nombre decidido y documentado como **ADR-0016** (estado "Aceptado" tras la revisión del miércoles).
- El DNS resuelve el host.
- Una **subida de prueba con URL prefirmada** contra ese host funciona con **certificado válido**.

---

### Cierre de la semana (Viernes 02/10) — Runners de CI y verificación G0

**Qué hacer:**
1. Asegurar que los runners de CI sostienen los 4 repos con **caché de dependencias** (Go modules,
   Cargo registry, capas Docker) para que un push no tarde una eternidad: caché es la diferencia
   entre CI usado y CI esquivado.
2. Recorrer la tabla de tareas y mover cada una a `HECHA` solo si cumple su DoD.
3. Preparar la demo del esqueleto y participar en la retrospectiva (salida: 3 acciones de mejora
   con owner).

**Puerta G0 (fin S0) — checklist para P1:**
- [ ] 4 repos creados, `main` protegida, CI en verde en todos (`S0-P1-01`).
- [ ] Toolchains versionadas y `bootstrap.sh` probado por otra persona (`S0-P1-02`).
- [ ] `docker compose --profile full up` levanta todo en < 3 min sin errores (`S0-P1-03`).
- [ ] Secreto de prueba detectado por gitleaks y revertido (`S0-P1-04`).
- [ ] Redes `edge`/`internal`/`data` verificadas sin salida a internet para datos (`S0-P1-05`).
- [ ] Ningún contenedor sin límite en `docker stats` (`S0-P1-06`).
- [ ] **ADR-0016 aceptada, DNS de `s3.<dominio>` resolviendo, subida prefirmada con cert válido** (`S0-P1-07`).

**Si G0 es No-Go:** semana de refuerzo; no se toca producción hasta cumplir.
