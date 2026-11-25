# QA lifecycle harness

Arranque y apagado del stack de desarrollo con verificacion de salud real.
Los comandos se invocan desde el despachador:

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

| Comando | Que hace |
|---|---|
| `up` | Levanta el stack con el perfil pedido y verifica salud real. |
| `status` | Estado de solo lectura (texto o `--json`). No muta nada. |
| `down` | Detiene servicios sin borrar datos; `--volumes` exige confirmacion. |
| `doctor` | Diagnostico de herramientas, `.env`, secretos, certs y compose. |

### `up`

```bash
qa.sh up [--profile core|full|discovery|sentinel|all] [--build]
         [--init-secrets] [--no-init] [--timeout <s>] [--no-wait] [--dry-run]
```

- `--profile` (default `full`). `full` y `all` implican `sentinel` porque
  `doc-service` resuelve Redis por Sentinel. `--profile core` levanta solo datos.
- `--init-secrets` genera **solo** los secretos de desarrollo faltantes (nunca pisa los existentes).
- `--no-init` prohibe crear `.env`; si falta, falla con codigo 3.
- `--no-wait` levanta sin esperar gates. `--dry-run` imprime lo que haria.
- Nunca ejecuta `down -v` ni recrea volumenes. Si el stack ya estaba arriba, no lo apaga.

Los gates incluyen `mongo` como primario del replica set, `mongo-init` y
`minio-init` con exit 0, `sentinel-1..3`, las replicas de Redis Streams y una
verificacion real de `SENTINEL get-master-addr-by-name myprimary`.

### `status` / `down`

```bash
qa.sh status [--json]
qa.sh down [--profile <p>] [--volumes] [--force] [--dry-run]
```

- `status --json` es consumible por CI; incluye sentinels, replicas y el master
  reportado por Sentinel.
- `down` hace `stop` (conserva datos). El default detiene `full + sentinel + core`,
  que es lo que arranca el default de `up`.
- `--volumes` es irreversible y exige escribir literalmente `infra`; no existe
  `--yes`. `--force` amplia el `stop` a todos los perfiles.
- `down` nunca toca proyectos `qa-it-*`: los lista con el comando exacto de limpieza.

## Codigos de salida

| Codigo | Significado |
|---|---|
| 0 | Exito |
| 2 | Preflight o workspace invalido |
| 3 | Configuracion faltante o invalida (`.env`, secretos, certs) |
| 4 | Timeout de salud |
| 5 | Dependencia externa no disponible (daemon, puerto ocupado, compose) |

## Variables de entorno

| Variable | Default | Uso |
|---|---|---|
| `QA_PROJECT` | `infra` | Proyecto Compose del entorno de desarrollo |
| `QA_RUN_ID` | `YYYYMMDDTHHMMSS-PID` | Identificador de corrida |
| `QA_ARTIFACTS_DIR` | `infra/.local/qa` | Raiz de artefactos |
| `QA_LOG_LEVEL` | `info` | `debug` agrega trazas de espera |

Las variables del proyecto (`TRAEFIK_HTTPS_PORT`, `MINIO_PUBLIC_ENDPOINT`,
`REDIS_STREAM_KEY`, etc.) se leen siempre de `infra/.env` con `env_value`;
nunca se duplican con defaults distintos.

## Artefactos

```
infra/.local/qa/<run-id>/
└── up.json    # resultado de cada gate de salud
```

Los logs se filtran con `qa_redact` (`PASSWORD`, `TOKEN`, `SECRET`, `signature`,
`X-Amz-*`, credenciales en URLs) y se truncan a 5 MB con aviso explicito.
