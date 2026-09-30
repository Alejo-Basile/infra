# Plan Detallado — Tarea `S0-P1-01`: Crear los 4 repositorios y su estructura

> **Contexto:** Guía operativa completa para P1 (Platform / DevOps / SRE) de la primera tarea de la
> Semana 0 (Lunes 28/09). Deriva del SDD `SPEC.md` **v2.1** y del plan `plan-S0-P1.md`.
>
> | Campo | Valor |
> |---|---|
> | ID | `S0-P1-01` |
> | Owner | P1 (único) |
> | Día | Lunes 28/09 |
> | Prioridad | **P0** (bloquea a todas las tareas `S0-*` de las 4 personas) |
> | Depende de | — |
> | Bloquea a | `S0-P1-02` a `S0-P1-07`, `S0-P2-*`, `S0-P3-*`, `S0-P4-*` |

**Criterio de aceptación (DoD):** cada uno de los 4 repos tiene README, licencia, `.gitignore`,
plantilla de PR, y una CI que corre en verde en el primer push. Rama `main` protegida.

---

## 1. Por qué esta tarea es P0 y es la primera

El proyecto usa la estrategia **multi-repo + Inverse Conway** (SPEC §2): cada servicio vive en su
propio repositorio y cada persona es dueña de un servicio y de su pipeline. Eso significa que **sin
los 4 repos, nadie puede arrancar**: P2 no tiene dónde poner el esqueleto de Go, P3 no tiene dónde
poner el de Rust, y P4 no tiene dónde construir el arnés de pruebas ni el `rate-limiter`.
Las convenciones (ramas protegidas, plantilla de PR, CI desde el primer push) se fijan **aquí**:
si se crean mal, corregir la gobernanza después cuesta más que hacerlo bien el lunes por la mañana.

---

## 2. Repositorios a crear

| Repo | Dueño | Contenido | Stack |
|---|---|---|---|
| `infra/` | **P1** | Docker Compose (perfiles `core`/`full`/`chaos`), config de Traefik, MinIO, Redis, Mongo, Prometheus/Grafana/Loki, scripts (`bootstrap.sh`), runbooks y ADRs | YAML, shell |
| `doc-service/` | P2 | Document Management Service: API de documentos, webhook MinIO, relay Change Streams, máquina de estados SAGA, reconciliador | Go / Gin |
| `extraction-worker/` | P3 | Extraction Worker: consumer group de Redis Streams, extracción de PDF, Retry + Circuit Breaker, DLQ | Rust / Tokio + Actix |
| `platform-services/` | P4 | Contendrá `rate-limiter/` (servicio ForwardAuth) y el arnés de pruebas E2E/contrato | Go, k6 |

---

## 3. Pasos de ejecución

### Paso 1 — Crear los 4 repositorios en el proveedor Git

Crear los 4 repos (GitHub/GitLab/Gitea, el que use el equipo), **privados**, con nombres exactos de
la tabla anterior. No inicializar con contenido que habrá que pisar; el primer commit lo hace P1
con la estructura estándar.

### Paso 2 — Estructura base común (plantilla)

Cada repo nace con el mismo set mínimo de archivos en el primer commit:

```
<repo>/
├── README.md                 # qué hace y qué NO hace este repo
├── LICENSE                   # licencia acordada por el equipo
├── .gitignore                # propio del stack (ver abajo)
├── .env.example              # solo valores ficticios, sin secretos reales
├── CODEOWNERS                # quién apruba qué
├── .github/
│   ├── pull_request_template.md
│   └── workflows/ci.yml      # CI mínima (o equivalente según proveedor)
└── docs/
    └── adr/                  # ADRs del repo (infra/ además guarda las ADRs globales)
```

**Reglas para estos archivos:**
- **README.md:** debe contestar en 3 párrafos: *qué hace*, *qué NO hace* (límites de
  responsabilidad), y *cómo se compila/testea/localiza en la arquitectura* (mermaid del SPEC §2).
- **`.gitignore`** por stack:
  - `infra/`: `*.env` (los reales), `acme.json`, volúmenes/dumps locales, `*.pem`.
  - `doc-service/`: binarios Go, `vendor/`, cobertura.
  - `extraction-worker/`: `target/`, `Cargo.lock` sí se commitea (es aplicación, no librería).
  - `platform-services/`: mezcla Go + artefactos k6 (`results/`).
- **`.env.example`:** nombres de variables con valores ficticios (`MINIO_ROOT_USER=changeme`).
  Nada de secretos reales jamás en el repo (criterio de seguridad n.º 2).
- **`CODEOWNERS`:** `@P1` en `infra/` y `platform-services/` (co-owner con P4); `@P2` en
  `doc-service/`; `@P3` en `extraction-worker/`. En `infra/` además: `docs/adr/ @P1 @P2 @P3 @P4`
  (las ADRs las revisan los 4).
- **Plantilla de PR** (`.github/pull_request_template.md`) con 4 secciones obligatorias
  (regla §3.2 de `pasos-iniciales.md`): *qué cambia · por qué · cómo se prueba · cómo se revierte*.

### Paso 3 — Proteger la rama `main`

Configurar en cada repo (vía API del proveedor o UI; documentar el comando/clic en el PR):

- Requerir PR antes de merge; **push directo a `main` denegado**.
- **Force push sobre `main` denegado.**
- Requerir CI en verde antes de merge (status checks obligatorios).
- Mínimo **1 aprobación**; 2 para PRs que toquen consistencia/idempotencia/camino crítico de
  seguridad (se refuerza vía CODEOWNERS en esas rutas).
- Rebase por defecto; merge squash permitido solo para PRs > 20 archivos.

### Paso 4 — CI mínima en el primer push

El objetivo de hoy **no** es el pipeline completo (eso es `S0-P1-04` y la maduración de F1), sino
un workflow que ya corre verde para probar que la protección funciona. Por repo:

| Repo | Job mínimo del lunes |
|---|---|
| `infra/` | Lint de YAML (`yamllint`) + validación de `docker compose config` |
| `doc-service/` | `go vet ./...` + `gofmt -l .` (o `golangci-lint run` si ya está listo) |
| `extraction-worker/` | `cargo fmt --check` + `cargo clippy -- -D warnings` (toolchain fijada con `rust-toolchain.toml`) |
| `platform-services/` | Lint de YAML + shellcheck sobre scripts |

Verificar el ciclo completo con un push de prueba: rama `chore/ci-bootstrap` → PR → CI corre en
verde → merge → `main` sigue protegida (intentar un push directo falla **a propósito** y se guarda
evidencia).

### Paso 5 — Documentar dónde se guardó todo

- Actualizar el `README.md` del workspace/docs con los enlaces a los 4 repos.
- Registrar en el tablero de la semana la tarea como `EN REVISION` y pedir revisión de una segunda
  persona (regla P0) antes de marcarla `HECHA`.

---

## 4. Verificación final (checklist DoD)

- [ ] Los 4 repos existen, son privados y tienen el primer commit con la estructura del Paso 2.
- [ ] `main` está protegida en los 4: push directo y force push fallan (probado adrede).
- [ ] Cada repo tiene README (qué hace/qué NO hace), LICENSE, `.gitignore`, `.env.example`
      ficticio, `CODEOWNERS` y plantilla de PR.
- [ ] Cada repo tiene una CI que corre **en verde** sobre el primer PR de prueba.
- [ ] Ningún secreto real en ningún archivo (autocomprobación rápida con `gitleaks detect`
      —aunque el hook formal es `S0-P1-04`, aquí ya no debe pasar nada).
- [ ] Enlaces publicados al equipo; tarea movida a `HECHA` con evidencia.

## 5. Reversibilidad

El cambio es trivialmente reversible: borrar recrear un repo antes de que nadie tenga trabajo
encima es gratis **hoy**; a partir de mañana ya no. Por eso las convenciones de este paso
(protección de `main`, plantilla de PR, CODEOWNERS) se revisan con calma *ahora* y no "sobre la
marcha" durante F1.
