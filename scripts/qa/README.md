# QA automation harness

Automatización transversal del workspace multi-repo: ciclo de vida del stack,
pruebas por microservicio y suites E2E con artefactos reproducibles.
Diseño completo en `docs/plan-automatizacion-qa.md`; contratos de cada helper
en `scripts/qa/lib/*.sh`.

Todo se invoca desde un único despachador:

```bash
infra/scripts/qa/qa.sh <comando> [opciones]
```

## Arranque y apagado en un comando

```bash
# Arranca la aplicacion completa (full + sentinel) y verifica salud real.
infra/scripts/start-all.sh

# Detiene la aplicacion sin borrar volumenes ni datos.
infra/scripts/stop-all.sh
```

Los wrappers reenvian argumentos a `qa.sh up` / `qa.sh down`, asi que aceptan
`--dry-run`, `--profile`, `--init-secrets`, etc. `start-all.sh` es idempotente:
si el stack ya esta arriba, no lo recrea ni lo apaga.

## Comandos

| Comando | Qué hace |
|---|---|
| `up` | Levanta el stack con el perfil pedido y verifica salud real. |
| `status` | Estado de solo lectura (texto o `--json`). No muta nada. |
| `down` | Detiene servicios sin borrar datos; `--volumes` exige confirmación. |
| `test <destino>` | lint / unit / integration por servicio. |
| `e2e [suites…]` | Suites de punta a punta con diagnóstico ante fallo. |
| `doctor` | Diagnóstico de herramientas, `.env`, secretos, certs y compose. |

### `up`

```bash
qa.sh up [--profile core|full|discovery|sentinel|all] [--build]
         [--init-secrets] [--no-init] [--timeout <s>] [--no-wait] [--dry-run]
```

- `--profile` (default `full`). `full` y `all` implican `sentinel` porque
  `doc-service` resuelve Redis por Sentinel. `--profile core` levanta solo datos.
- `--init-secrets` genera **solo** los secretos de desarrollo faltantes (nunca pisa los existentes).
- `--no-init` prohíbe crear `.env`; si falta, falla con código 3.
- `--no-wait` levanta sin esperar gates. `--dry-run` imprime lo que haría.
- Nunca ejecuta `down -v` ni recrea volúmenes. Si el stack ya estaba arriba, no lo apaga.

Los gates incluyen `sentinel-1..3`, las réplicas de Redis Streams y una
verificación real de `SENTINEL get-master-addr-by-name myprimary`.

### `status` / `down`

```bash
qa.sh status [--json]
qa.sh down [--profile <p>] [--volumes] [--force] [--dry-run]
```

- `status --json` es consumible por CI y por `e2e.sh`; incluye sentinels,
  réplicas y el master reportado por Sentinel.
- `down` hace `stop` (conserva datos). El default detiene `full + sentinel + core`,
  que es lo que arranca el default de `up`.
- `--volumes` es irreversible y exige escribir literalmente `infra`; no existe
  `--yes`. `--force` amplía el `stop` a todos los perfiles.
- `down` nunca toca proyectos `qa-it-*`: los lista con el comando exacto de limpieza.

### `test`

```bash
qa.sh test <destino> [--lint|--unit|--integration|--all]
         [--no-deps] [--keep-deps] [--timeout <s>] [--json]
```

Destinos: `doc-service`, `extraction-worker`, `ocr-worker`,
`platform-services`, `infra`, `all`. Sin selector ejecuta `--all`
(lint → unit → integration, secuencial).

La integración levanta un proyecto Compose efímero propio
(`qa-it-<servicio>-<run-id>`) con puertos loopback desde `QA_PORT_BASE`
(default `27117`) y lo destruye con `down -v` al salir. `--no-deps` usa el
entorno actual; `--keep-deps` deja el stack efímero para depurar e imprime el
comando de limpieza.

### `e2e`

```bash
qa.sh e2e [suites…] [--runs <n>] [--slow] [--keep-stack] [--keep-data]
          [--fail-fast] [--timeout <s>] [--list] [--json] [--dry-run]
```

Sin argumentos ejecuta `ci` (`smoke happy states errors correlation`).
Resuelve el stack con `status.sh --json`: lo reutiliza si está sano, lo levanta
si falta (recordando `started_by_runner`) y falla con código 5 si está a medias.
Nunca borra volúmenes; al terminar solo hace `stop` si lo levantó el runner.

## Códigos de salida

| Código | Significado |
|---|---|
| 0 | Éxito |
| 1 | Falla de test/suite (o `blocked`) |
| 2 | Preflight o workspace inválido |
| 3 | Configuración faltante o inválida (`.env`, secretos, certs) |
| 4 | Timeout de salud o de suite |
| 5 | Dependencia externa no disponible (daemon, puerto ocupado, compose) |

## Variables de entorno

| Variable | Default | Uso |
|---|---|---|
| `QA_PROJECT` | `infra` | Proyecto Compose del entorno de desarrollo |
| `QA_PORT_BASE` | `27117` | Base de los puertos de integración |
| `QA_MONGO_PORT`, `QA_REDIS_PORT`, `QA_MINIO_PORT` | base, base+1, base+2 | Overrides por puerto |
| `QA_SENTINEL_PORT_{1,2,3}` | base+3..base+5 | Sentinels efímeros |
| `QA_RUN_ID` | `YYYYMMDDTHHMMSS-PID` | Identificador de corrida y prefijo de datos |
| `QA_ARTIFACTS_DIR` | `infra/.local/qa` | Raíz de artefactos |
| `QA_TIMEOUT_UNIT` | `120` | Timeout de unitarios (s) |
| `QA_TIMEOUT_INTEGRATION` | `600` | Timeout de integración (s) |
| `QA_TIMEOUT_E2E` | `420` | Timeout default por suite E2E (s) |
| `QA_KEEP_DEPS` | `0` | No destruir el stack efímero |
| `QA_KEEP_STACK` | `0` | No apagar el stack al final del E2E |
| `QA_KEEP_DATA` | `0` | No borrar los datos del run |
| `QA_LOG_LEVEL` | `info` | `debug` agrega trazas de espera |

Las variables del proyecto (`TRAEFIK_HTTPS_PORT`, `MINIO_PUBLIC_ENDPOINT`,
`REDIS_STREAM_KEY`, etc.) se leen siempre de `infra/.env` con `env_value`;
nunca se duplican con defaults distintos.

## Artefactos

```
infra/.local/qa/<run-id>/          # modo 700
├── up.json                        # resultado de cada gate de salud
├── test-<servicio>/
│   ├── lint.log unit.log integration.log
│   ├── results.json junit.xml
│   └── deps.env                   # URIs con credenciales de dev, modo 600
├── e2e/
│   ├── <suite>.log
│   ├── results.json junit.xml
│   └── diagnostics/               # solo ante fallo
└── deps.env
```

Los logs se filtran con `qa_redact` (`PASSWORD`, `TOKEN`, `SECRET`,
`signature`, `X-Amz-*`, credenciales en URLs) y se truncan a 5 MB con aviso
explícito. `results.json` nunca contiene URIs con credenciales.

## Mapa de suites E2E

| Suite | Perfil | Timeout | Lenta | Implementación |
|---|---|---|---|---|
| `smoke` | full | 180 s | no | `platform-services/tests/e2e/run.sh smoke` |
| `happy` | full | 300 s | no | `platform-services/tests/e2e/run.sh happy --runs N` |
| `states` | full | 420 s | no | `platform-services/tests/e2e/states/run.sh` |
| `errors` | full | 420 s | no | `platform-services/tests/e2e/errors/run.sh` |
| `correlation` | full | 300 s | no | `platform-services/tests/e2e/correlation/run.sh --runs N` |
| `chain` | full | 420 s | no | `platform-services/tests/e2e/chain/run.sh --runs N` |
| `routing` | full | 120 s | no | `infra/scripts/test-routing-table.sh` |
| `consul` | full+discovery | 300 s | no | `test-consul.sh` + `verify-consul-boundaries.sh` |
| `resilience` | full+sentinel | 900 s | sí | `infra/scripts/e2e-horizontal-scaling.sh` |
| `load` | full | 1200 s | sí | `platform-services/tests/e2e/load/run.sh` |
| `chaos` | full+chaos | 1800 s | sí | `chaos/run.sh --all` + `test-minio-disk-fill.sh` + `test-chain-alerts.sh` |
| `replay` | stack replay propio | 1800 s | sí | `infra/scripts/replay-env.sh` |
| `parity` | full (monolito) | 1800 s | sí | `python3 -m unittest discover -s platform-services/tests/parity` |
| `ci` | full | 1800 s | no | `smoke happy states errors correlation` |
| `all` | full+discovery | 1800 s | — | todas las no lentas |
| `all --slow` | todas | 5400 s | — | todas |

Las suites lentas sin `--slow` se registran como `skip` con motivo
`requires --slow`, nunca como fallo. `chaos` y `resilience` corren en serie y
avisan antes de detener contenedores: el flag `--slow` es la autorización.

`e2e-01.sh` queda como comando histórico. La suite canónica equivalente es
`happy`; `e2e.sh` no invoca `e2e-01.sh` para no mantener dos veces el mismo flujo.

## Verificación de convergencia

Al final de cada corrida con suites ejecutadas, el runner consulta Mongo por
documentos `qa-<run-id>-*` en estados no terminales
(`COMPLETED|FAILED|REJECTED|UPLOAD_EXPIRED`) y registra el check `convergence`.
Luego borra los documentos y objetos del run (`raw-pdfs/<id>.pdf`,
`extracted-txt/<id>.txt`) salvo `--keep-data`. Nunca toca datos del dev.

## Seguridad

- Nunca se imprimen valores de `infra/secrets/*` ni de `.env`; solo nombres y
  booleanos de existencia.
- Logs persistidos pasan por `qa_redact`; artefactos con `umask 077`.
- `docker-compose.test.yml` publica **solo** en `127.0.0.1`.
- No se usa `eval` sobre valores de `.env`; todas las expansiones van citadas.
- `down --volumes` es la única acción destructiva y exige escribir `infra`.
- `test infra --lint` corre `gitleaks` a través del CI del repo; el arnés no
  introduce secretos en archivos versionados.

## Limitaciones y desviaciones aplicadas

1. **`doc-service` hermetic CI lleva `|| true` upstream.** El arnés ejecuta el
   mismo comando **sin** `|| true` para que un fallo real no pase inadvertido.
   Es un defecto del workflow de CI del repo, documentado aquí a propósito.
2. **Mongo efímero** re-bindea `0.0.0.0` y los tests usan
   `directConnection=true`: el compose de desarrollo limita el bind a
   `localhost,mongo` y el Replica Set anuncia `mongo:27017`.
3. **Sentinels efímeros** anuncian IPs de contenedor (`announce-hostnames no`,
   `protected-mode no`) para que un proceso del host las alcance. Los tests de
   failover Sentinel requieren el bridge de Linux; en Docker Desktop no son
   enrutables.
4. **Reintentos de init.** MinIO responde `/minio/health/live` antes de cargar
   IAM, lo que hacía fallar `minio-init` de forma intermitente. El override de
   test gatea con `/minio/health/cluster` y el arnés reintenta los jobs
   idempotentes (`mongo-init`, `minio-init`, `minio-notify-init`).
5. **`openssl` y `shellcheck` son opcionales** en local: `--init-secrets`
   necesita `openssl`; `test infra --lint` reporta `blocked` si falta
   `shellcheck` en vez de declarar verde.

## Limpieza manual

```bash
# Proyectos efímeros de integración que hayan quedado de una corrida interrumpida
docker compose ls --format json | jq -r '.[] | select(.Name|startswith("qa-it-")) | .Name'
docker compose -p <proyecto> down -v --remove-orphans

# Stack de desarrollo (conserva datos)
./scripts/qa/qa.sh down

# Stack de desarrollo + volúmenes (IRREVERSIBLE, pide confirmación)
./scripts/qa/qa.sh down --volumes
```

Si el `.env` de desarrollo tiene placeholders y sólo querés trabajar localmente:

```bash
./scripts/qa/qa.sh up --init-secrets    # secretos de DESARROLLO, nunca de producción
```
