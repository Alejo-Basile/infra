#!/bin/sh
# Entrypoint de los contenedores Sentinel (S1-P1-08, plan-S2-P1.md §4).
# Genera /tmp/sentinel.conf desde la plantilla y arranca redis-server --sentinel.
#
# La imagen redis:7.2 NO trae `envsubst` (verificado con `command -v`), por lo
# que la sustitucion se hace con `sed`. El password solo existe en el
# contenedor (variable de entorno) y en /tmp (modo 600, dueno `redis`).
set -eu

umask 077

: "${REDIS_STREAMS_PASSWORD:?definir REDIS_STREAMS_PASSWORD en .env}"

TMPL=/usr/local/etc/redis/sentinel.conf.tmpl
OUT=/tmp/sentinel.conf

# Escapa `\` y `&` del password para la parte de reemplazo de sed.
PW_ESC=$(printf '%s' "$REDIS_STREAMS_PASSWORD" | sed 's/[\\&]/\\&/g')

sed "s|\${REDIS_STREAMS_PASSWORD}|${PW_ESC}|g" "$TMPL" > "$OUT"
chown redis:redis "$OUT"

# El entrypoint oficial hace el drop de privilegios a `redis` (setpriv).
exec /usr/local/bin/docker-entrypoint.sh redis-server "$OUT" --sentinel
