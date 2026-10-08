#!/bin/sh
# MinIO: notificaciones de bucket (webhook) -> doc-service — SPEC §5.2 / S3-P2-05.
# Idempotente: re-aplica el target webhook y la suscripcion de eventos.
# Se ejecuta como job efimero tras `minio` healthy y con `doc-service` arrancado.
set -e

ALIAS="local"
TARGET="docservice"
BUCKET="raw-pdfs"
ARN="arn:minio:sqs::${TARGET}:webhook"

: "${MINIO_ROOT_USER:?MINIO_ROOT_USER requerido}"
: "${MINIO_ROOT_PASSWORD:?MINIO_ROOT_PASSWORD requerido}"
: "${MINIO_WEBHOOK_SECRET:?MINIO_WEBHOOK_SECRET requerido}"
: "${DOC_SERVICE_WEBHOOK_URL:?DOC_SERVICE_WEBHOOK_URL requerido}"

wait_minio() {
  i=0
  while [ "$i" -lt 40 ]; do
    if mc ready "$ALIAS" >/dev/null 2>&1; then return 0; fi
    i=$((i + 1))
    sleep 1
  done
  echo "ERROR: MinIO no quedo listo tras el restart" >&2
  return 1
}

mc alias set "$ALIAS" "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4 >/dev/null

# --- Target webhook -----------------------------------------------------------
# El target esta declarado en el arranque de MinIO via MINIO_NOTIFY_WEBHOOK_*
# (compose), por lo que normalmente NO hace falta restart. Si la config no se
# llego a aplicar (ej. MinIO arrancado antes del cambio), se intenta re-aplicar
# con `mc admin service restart`, cuyo fallo sin TTY se tolera: sin TTY la
# config sigue pendiente y se require reiniciar el contenedor minio desde el
# host (docker compose restart minio).
# Con auth_token de una sola palabra MinIO inyecta `Authorization: Bearer <token>`,
# que es justo lo que valida el handler de doc-service (SPEC §5.2).
mc admin config set "$ALIAS" "notify_webhook:${TARGET}" \
  endpoint="${DOC_SERVICE_WEBHOOK_URL}" \
  auth_token="${MINIO_WEBHOOK_SECRET}" >/dev/null 2>&1 \
  || echo "AVISO: target notify_webhook:${TARGET} no editable (revisar config)"

if mc admin config get "$ALIAS" "notify_webhook:${TARGET}" 2>/dev/null \
    | grep -q "endpoint=${DOC_SERVICE_WEBHOOK_URL}"; then
  echo "Target notify_webhook:${TARGET} activo -> ${DOC_SERVICE_WEBHOOK_URL}"
else
  echo "Target no confirmado: aplicando restart interno (puede fallar sin TTY)."
  mc admin service restart "$ALIAS" >/dev/null 2>&1 || true
  wait_minio
fi

# --- Suscripcion de eventos ---------------------------------------------------
# Solo ObjectCreated (`put`): la subida prefirmada POST termina en un PUT del objeto.
if mc event list "$ALIAS/$BUCKET" 2>/dev/null | grep -q "${TARGET}"; then
  echo "Evento ya suscrito en ${BUCKET} (${ARN})"
else
  mc event add "$ALIAS/$BUCKET" "$ARN" --event put
fi

echo "Eventos configurados en ${BUCKET}:"
mc event list "$ALIAS/$BUCKET"
echo "MinIO notificaciones inicializadas."
