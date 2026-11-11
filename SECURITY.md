# Política de Seguridad

## Reporte de vulnerabilidades

Este repositorio es público y contiene configuración de infraestructura. Si encuentras una vulnerabilidad o un secreto expuesto:

1. **No** abras una issue pública.
2. Usa la pestaña **Security → Report a vulnerability** (GitHub Private Vulnerability Reporting), o contacta directamente al maintainer: `@Alejo-Basile`.
3. Incluye: archivo/commit afectado, tipo de exposición y pasos para reproducir.

## Reglas permanentes

- Ningún secreto real entra al repo: solo `.env.example` con valores ficticios (SPEC §9).
- Si un secreto llega a un commit: revocar inmediatamente, purgar historial y rotar credenciales.
- Las imágenes base usan pin por digest y los contenedores propios corren como usuario no-root.

## Inventario de secretos (S2-P1-01)

Los valores viven **solo** en el host, fuera de git:

- `infra/.env` — valores de interpolación (git-ignored por `*.env`).
- `infra/secrets/` — Docker secrets como archivos (git-ignored por `secrets/*`).

El compose solo referencia los secretos: variables `*_FILE` que apuntan a `/run/secrets/<nombre>` o un bloque `secrets:` que monta el archivo. `docker compose config` no debe mostrar valores en claro (salvo las excepciones de traspaso listadas abajo).

| Secreto (`secrets/…`) | Consumidor(es) | Inyección |
|---|---|---|
| `mongo_initdb_root_password.txt` | `mongo`, `mongo-init` | `MONGO_INITDB_ROOT_PASSWORD_FILE` + healthcheck; `init.js` resuelve `*_FILE` |
| `mongo_app_password.txt` | `doc-service`, `mongo-init` | entrypoint → `MONGO_APP_PASSWORD`; `init.js` `*_FILE` |
| `mongo_worker_password.txt` | `extraction-worker`, `mongo-init` | entrypoint → `MONGO_WORKER_URI`; `init.js` `*_FILE` |
| `mongo_keyfile` | `mongo` | bind mount ro en `/etc/mongo/keyfile` (ver material de staging) |
| `redis_streams_password.txt` | `redis-streams`, réplicas, `sentinel-*`, `doc-service`, `extraction-worker` | `*_FILE` + entrypoints |
| `redis_streams_password.json` | `redis-exporter` (y variantes) | `REDIS_PASSWORD_FILE` (mapa URI→password) |
| `redis_ratelimit_password.txt` | `redis-ratelimit` | entrypoint → `--requirepass` |
| `minio_root_password.txt` | `minio`, `minio-init`, `minio-notify-init` | `MINIO_ROOT_PASSWORD_FILE`; scripts resuelven `*_FILE` |
| `minio_webhook_secret.txt` | `minio`, `doc-service`, `minio-notify-init` | wrapper compose → `MINIO_NOTIFY_WEBHOOK_AUTH_TOKEN_DOCSERVICE`; entrypoint doc-service → `MINIO_WEBHOOK_SECRET`; `MINIO_WEBHOOK_SECRET_FILE` en el job |
| `internal_token.txt` | `doc-service` | entrypoint → `INTERNAL_TOKEN` |
| `grafana_admin_password.txt` | `grafana` | `GF_SECURITY_ADMIN_PASSWORD_FILE` |
| `svc_docservice_access_key.txt`, `svc_docservice_secret_key.txt` | `doc-service`, `minio-init` | `*_FILE` |
| `svc_worker_access_key.txt`, `svc_worker_secret_key.txt` | `extraction-worker`, `minio-init` | `*_FILE` |

### Secreto compartido del webhook (SPEC §5.2, §9)

MinIO firma cada POST a `/internal/storage/events` con `Authorization: Bearer <token>`, usando el
`auth_token` del target `notify_webhook:DOCSERVICE`. Ese token es `minio_webhook_secret`:

- MinIO lo lee de `/run/secrets/minio_webhook_secret` (wrapper de entrypoint, porque el loop `*_FILE`
  de Bitnami no cubre `MINIO_NOTIFY_*`).
- doc-service lo lee de `/run/secrets/minio_webhook_secret` y valida `X-Minio-Webhook-Token` o
  `Authorization: Bearer`. Token inválido → `401`.
- Ambos lados comparten el mismo archivo: rotarlo exige recrear `minio`, `doc-service` y
  `minio-notify-init` (ver runbook). El valor viejo queda revocado al no existir ya en el store.

### Rol de Mongo del worker (SPEC §6.3, ADR-0006)

`init.js` crea el rol `documentsUpdater` con **solo `update`** sobre `documents` (sin `find`,
`insert`, `delete`, `drop` ni admin) y un usuario `MONGO_WORKER_USER` distinto del de doc-service.
El rol es correctivo: si existía con privilegios de más, `updateRole` los reduce. Verificación en
vida: `find`/`insert`/`delete` → `Unauthorized (13)`, `update` → permitido.

## Material de staging y secretos auditados

- **`mongo_keyfile`** — keyFile del Replica Set. Auditoría (S2-P1-01): es un secreto **real**
  (1024 bytes base64 aleatorio, generado por entorno con `openssl rand -base64 756`), **nunca**
  estuvo trackeado en git (sin historial que purgar). Desde S2-P1-01 vive en `secrets/mongo_keyfile`
  (dueño `999:999`, modo `400`, git-ignored) y el compose lo monta desde ahí. Se trata como material
  de staging: es único de este entorno y nunca sale del host.
- **Certificados de Traefik** — `traefik/certs/*.pem` son certificados locales de `mkcert`
  (git-ignored por `traefik/certs/.gitignore`), no credenciales. `traefik/traefik.yml` **no**
  configura ACME todavía (variante local); en producción el email de ACME es configuración y las
  credenciales del resolver (si se usan, p. ej. DNS-01) deberán entrar como Docker secret. Hoy **no
  existe ninguna credencial ACME** que guardar.

## Limitaciones conocidas (traspaso a los equipos de servicio)

Variables que el compose todavía interpola en texto claro porque la aplicación las consume como env
directo (cambiarlas requiere código del servicio, fuera de S2-P1-01):

- `doc-service`: `MONGO_URI` (incluye el password de `MONGO_APP_USER`). El servicio debe aceptar
  `MONGO_APP_USER` + un password por archivo y armar la URI él mismo.
- `monolito`: `MONGO_USER` / `MONGO_PASS` se pasan como environment directo (su imagen no admite un
  wrapper de entrypoint sin conocer el original).
- `mongo-init`: `MONOLITO_MONGO_PASSWORD` (crea el usuario legacy del monolito); ligado a la misma
  limitación del monolito.

Mientras existan, `docker compose config` mostrará esos valores al interpolar `.env`; no están en el
árbol commiteado (`*.env` está git-ignored). El resto del inventario ya es solo referencias.

## Gate de secretos en CI

`.github/workflows/gitleaks.yml` corre `gitleaks/gitleaks-action@v2` sobre `push` a `main` y en cada
`pull_request`, sin `continue-on-error`: un hallazgo **falla** el pipeline (verificado localmente con
`gitleaks git` → exit 1 ante un token de prueba). La primera capa es el hook local de pre-commit.

## Hallazgos de vulnerabilidad de imagen (S1-P1-15, T5)

- **CVE-2023-45853 / zlib1g** se encontró en el worker previo basado en Debian 12 (`1:1.2.13.dfsg-1`); Trivy informó `will_not_fix`. Debian Trixie 13.7 fijado en `extraction-worker/Dockerfile` dio 0 CRITICAL; el artefacto reconstruido también dio 0, sin `ignore-unfixed`.
- **MongoDB 7.0.45 / gosu — excepción documentada:** el último digest disponible de la línea 7.0 sigue conteniendo gosu con Go stdlib 1.24.6 y `CVE-2025-68121`; no hay build 7.0 con gosu 1.24.13+. El servicio ejecuta como UID 999, de modo que el entrypoint no invoca gosu para cambiar de usuario. Riesgo residual: la herramienta vulnerable sigue dentro de la imagen y volver a un arranque root habilitaría ese camino. No se saltó a Mongo 8 porque requeriría una migración de datos mayor, fuera del alcance y sin backup verificado. Revaluar al publicar Mongo 7.0 con gosu corregido o planificar el upgrade mayor con backup/restore probado.
- **MinIO y minio-client Bitnami — excepción documentada:** los últimos tags de `bitnamilegacy` consultados (`minio` 2025.7.23, `minio-client` 2025.7.21) fueron publicados en agosto de 2025 y no hay builds posteriores en la línea. Los repositorios `minio/minio` y `minio/mc` consultados en Docker Hub devolvieron 404; `quay.io/minio/{minio,mc}` devolvió 502 desde este entorno, por lo que no hay digest alternativo verificable para desplegar. Hallazgos reportados incluyen `CVE-2026-111497`, `CVE-2026-33845`, `CVE-2026-42010`, `CVE-2026-13221`, `CVE-2026-42496`, `CVE-2026-8376`, `CVE-2026-31789`, `CVE-2026-77405`, `CVE-2026-77408`, `CVE-2026-77411`, `CVE-2026-33186` y `CVE-2025-68121`. Riesgo residual: librerías OS y Go antiguas permanecen en el servidor MinIO; el cliente vulnerable solo corre como init job y sale. Mitigaciones compensatorias: UID 1001, rootfs RO, límites, MinIO aislado en `data`, consola 9001 sin exposición y jobs de cliente de duración corta. Excepción temporal aceptada hasta que haya una imagen mantenida con digest verificable.
- Los gates CI de doc-service, extraction-worker e imagen probe de Loki usan severidad `CRITICAL` y `exit-code: 1`, sin `ignore-unfixed` ni `continue-on-error`.
- Las demás imágenes del stack fueron actualizadas a versiones con fixes disponibles y su resultado final de Trivy está en `infra/docs/evidencias/S5/S5-P1-10-hardening.txt`. Repetir el scan al actualizar cualquier digest.
