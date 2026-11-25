#!/bin/sh
# =============================================================================
# ocr-worker — entrypoint de contenedor.
# =============================================================================
set -eu

read_file_secret() {
    eval "secret_path=\${$1:-}"
    [ -n "${secret_path}" ] || return 0

    if [ ! -r "${secret_path}" ]; then
        echo "entrypoint: no puedo leer ${1}=${secret_path}" >&2
        exit 1
    fi

    secret_name=${1%_FILE}
    secret_value=$(cat "${secret_path}")
    if [ -z "${secret_value}" ]; then
        echo "entrypoint: ${1} esta vacio (${secret_path})" >&2
        exit 1
    fi
    export "${secret_name}=${secret_value}"
    unset secret_path secret_name secret_value
}

read_file_secret S3_ACCESS_KEY_FILE
read_file_secret S3_SECRET_KEY_FILE

urlencode() {
    printf '%s' "$1" | od -An -v -tx1 | tr ' ' '\n' | while IFS= read -r byte; do
        if [ -n "${byte}" ]; then
            printf '%%%s' "${byte}"
        fi
    done
}

if [ -z "${REDIS_URL:-}" ] && [ -n "${REDIS_PASSWORD_FILE:-}" ]; then
    redis_password=$(urlencode "$(cat "${REDIS_PASSWORD_FILE}")")
    export REDIS_URL="redis://:${redis_password}@${REDIS_HOST:-redis-streams}:${REDIS_PORT:-6379}/${REDIS_DB:-0}"
    unset redis_password
fi

bind="?authSource=${MONGO_OCR_DB:-documents}"
if [ -z "${MONGO_WORKER_URI:-}" ] && [ -n "${MONGO_OCR_PASSWORD_FILE:-}" ]; then
    mongo_password=$(urlencode "$(cat "${MONGO_OCR_PASSWORD_FILE}")")
    export MONGO_WORKER_URI="mongodb://${MONGO_OCR_USER:-ocr-worker}:${mongo_password}@${MONGO_OCR_HOST:-mongo}:27017/${MONGO_OCR_DB:-documents}${bind}"
    unset mongo_password
fi
unset bind

exec "$@"
