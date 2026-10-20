#!/bin/sh
# Entrypoint wrapper para doc-service (S2-P1-01).
# Lee los secretos desde /run/secrets/ y los exporta como variables de entorno
# antes de ejecutar la aplicacion. Asume que el binario es el CMD por defecto
# de la imagen.
set -e

export MONGO_APP_PASSWORD=$(cat /run/secrets/mongo_app_password)
export SVC_DOCSERVICE_ACCESS_KEY=$(cat /run/secrets/svc_docservice_access_key)
export SVC_DOCSERVICE_SECRET_KEY=$(cat /run/secrets/svc_docservice_secret_key)
export REDIS_STREAMS_PASSWORD=$(cat /run/secrets/redis_streams_password)
export MINIO_WEBHOOK_SECRET=$(cat /run/secrets/minio_webhook_secret)
export INTERNAL_TOKEN=$(cat /run/secrets/internal_token)

exec "$@"
