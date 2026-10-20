#!/bin/sh
# MinIO: notificaciones de bucket (webhook) -> doc-service — SPEC §5.2 / S3-P2-05.
# Idempotente: suscribe el evento ObjectCreated:Put del bucket raw-pdfs al
# target webhook que declara compose para minio (MINIO_NOTIFY_WEBHOOK_*).
# Se ejecuta como job efimero tras `minio` healthy y con `doc-service` arrancado.
#
# S3-P1-03: este job ya NO gestiona el target con `mc admin config set`.
# Antes duplicaba el target declarativo (mc: `docservice`) y le escribia el
# auth_token al config store, pero MinIO solo aplica esa config al reiniciar:
# con el proceso corriendo, el target quedaba sin token y cada webhook caia
# en 401 (hallazgo real del E2E de trazabilidad). El target declarativo
# (sufijo DOCSERVICE) se aplica en cada arranque desde el env de minio con
# el token de una sola fuente (compose/.env), asi que no puede desincronizarse.
# Este job verifica que el target este registrado, retira la suscripcion
# legacy del target mc si existe y suscribe el evento.
set -e

# --- Secret resolution: flat VAR or VAR_FILE (Docker secret) -------------------
# Usage: resolve_secret VAR_NAME
# Reads ${VAR_NAME}_FILE when set (Docker secret), otherwise keeps the flat
# variable. Fails on a missing/unreadable file or an empty value. The secret
# value is never printed.
resolve_secret() {
  _rs_var="$1"
  eval "_rs_file=\${${_rs_var}_FILE:-}"
  if [ -n "$_rs_file" ]; then
    if [ ! -r "$_rs_file" ]; then
      echo "ERROR: ${_rs_var}_FILE is missing or not readable: $_rs_file" >&2
      exit 1
    fi
    _rs_value=$(cat "$_rs_file" 2>/dev/null) || {
      echo "ERROR: ${_rs_var}_FILE could not be read: $_rs_file" >&2
      exit 1
    }
    export "${_rs_var}=${_rs_value}"
  fi
  eval "_rs_value=\${${_rs_var}:-}"
  if [ -z "$_rs_value" ]; then
    echo "ERROR: ${_rs_var} is empty (set it directly or via ${_rs_var}_FILE)" >&2
    exit 1
  fi
  unset _rs_file _rs_value
}

resolve_secret MINIO_ROOT_PASSWORD

ALIAS="local"
TARGET="DOCSERVICE"                    # sufijo de MINIO_NOTIFY_WEBHOOK_* (compose)
BUCKET="raw-pdfs"
ARN="arn:minio:sqs::${TARGET}:webhook" # MinIO completa la region al suscribir

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER requerido}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD requerido}"
: "${DOC_SERVICE_WEBHOOK_URL:?DOC_SERVICE_WEBHOOK_URL requerido}"

mc alias set "$ALIAS" "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 >/dev/null

# --- Target declarativo activo (lo aplica minio al arrancar desde su env) ------
TARGET_CFG="$(mc admin config get "$ALIAS" "notify_webhook:${TARGET}" 2>/dev/null || true)"
if ! printf '%s' "$TARGET_CFG" | grep -q "^notify_webhook:${TARGET}"; then
  echo "ERROR: notify_webhook:${TARGET} no esta registrado." >&2
  echo "       compose lo declara via MINIO_NOTIFY_WEBHOOK_*_${TARGET} y MinIO lo" >&2
  echo "       aplica al arrancar. Recrear minio desde el host:" >&2
  echo "         docker compose -f compose/docker-compose.yml --env-file .env --profile full up -d --force-recreate minio" >&2
  exit 1
fi
# Consistencia del endpoint (aviso, no fatal: el E2E es la verificacion real).
if ! printf '%s' "$TARGET_CFG" | grep -q "ENDPOINT_${TARGET}=${DOC_SERVICE_WEBHOOK_URL}"; then
  echo "AVISO: MINIO_NOTIFY_WEBHOOK_ENDPOINT_${TARGET} no coincide con DOC_SERVICE_WEBHOOK_URL; revisar compose/.env" >&2
fi

# --- Migracion S3-P1-03: retirar la suscripcion al target legacy mc -----------
LEGACY_ARN="$(mc event list "$ALIAS/$BUCKET" 2>/dev/null | awk '{print $1}' | grep ':docservice:webhook$' | head -1 || true)"
if [ -n "$LEGACY_ARN" ]; then
  if mc event remove "$ALIAS/$BUCKET" "$LEGACY_ARN" --event put >/dev/null 2>&1; then
    echo "Suscripcion legacy retirada: $LEGACY_ARN"
  else
    echo "ERROR: no se pudo retirar la suscripcion legacy $LEGACY_ARN" >&2
    exit 1
  fi
fi

# --- Suscripcion de eventos ---------------------------------------------------
# Solo ObjectCreated (`put`): la subida prefirmada POST termina en un PUT del objeto.
if mc event list "$ALIAS/$BUCKET" 2>/dev/null | grep -q ":${TARGET}:webhook"; then
  echo "Evento ya suscrito en ${BUCKET} (target ${TARGET})"
else
  mc event add "$ALIAS/$BUCKET" "$ARN" --event put
fi

echo "Eventos configurados en ${BUCKET}:"
mc event list "$ALIAS/$BUCKET"
echo "MinIO notificaciones inicializadas."
