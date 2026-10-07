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
# Con auth_token de una sola palabra MinIO inyecta `Authorization: Bearer <token>`,
# que es justo lo que valida el handler de doc-service (SPEC §5.2).
mc admin config set "$ALIAS" "notify_webhook:${TARGET}" \
  endpoint="${DOC_SERVICE_WEBHOOK_URL}" \
  auth_token="${MINIO_WEBHOOK_SECRET}" >/dev/null
echo "Target notify_webhook:${TARGET} -> ${DOC_SERVICE_WEBHOOK_URL}"

# Los cambios de notificacion se aplican al reiniciar el servicio de MinIO.
mc admin service restart "$ALIAS" >/dev/null 2>&1 || true
wait_minio

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
