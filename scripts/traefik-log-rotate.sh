#!/usr/bin/env bash
# Copy the live Traefik access log to a host archive, gzip it, prune old files.
set -euo pipefail

CONTAINER="${TRAEFIK_CONTAINER:-infra-traefik-1}"
ARCHIVE_DIR="${TRAEFIK_LOG_ARCHIVE:-$HOME/traefik-logs-archive}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --container) CONTAINER="$2"; shift 2 ;;
        --help) echo "Usage: $0 [--container NAME]"; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; exit 2 ;;
    esac
done

mkdir -p "${ARCHIVE_DIR}"
DATE="$(date -u +%F)"
OUT="${ARCHIVE_DIR}/access-${DATE}.log"
docker exec "${CONTAINER}" cat /var/log/traefik/access.log > "${OUT}"
gzip -f "${OUT}"
find "${ARCHIVE_DIR}" -name 'access-*.log.gz' -type f -mtime +"${RETENTION_DAYS}" -delete
echo "archived ${OUT}.gz (retention ${RETENTION_DAYS} days)"