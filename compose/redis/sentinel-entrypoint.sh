#!/bin/sh
# Entrypoint de los contenedores Sentinel (S1-P1-08, plan-S2-P1.md §4).
# Genera /tmp/sentinel.conf desde la plantilla y arranca redis-server --sentinel.
#
# La imagen redis:7.2 NO trae `envsubst` (verificado con `command -v`), por lo
# que la sustitucion se hace con `sed`. El password solo existe en el
# contenedor (variable de entorno) y en /tmp (modo 600, dueno `redis`).
#
# El secreto llega via Docker secrets (REDIS_STREAMS_PASSWORD_FILE en compose),
# no como variable plana. resolve_secret soporta ambas formas, con el mismo
# contrato que los scripts init de MinIO (S3-P1-03, 818d89b): falla si el
# archivo falta o no se puede leer o si el valor queda vacio, y nunca imprime
# el valor. Sin esto el entrypoint moria con exit 2 en el arranque.
set -eu

umask 077

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

resolve_secret REDIS_STREAMS_PASSWORD

TMPL=/usr/local/etc/redis/sentinel.conf.tmpl
OUT=/tmp/sentinel.conf

# Escapa `\` y `&` del password para la parte de reemplazo de sed.
PW_ESC=$(printf '%s' "$REDIS_STREAMS_PASSWORD" | sed 's/[\\&]/\\&/g')

sed "s|\${REDIS_STREAMS_PASSWORD}|${PW_ESC}|g" "$TMPL" > "$OUT"
chown redis:redis "$OUT"

# El entrypoint oficial hace el drop de privilegios a `redis` (setpriv).
exec /usr/local/bin/docker-entrypoint.sh redis-server "$OUT" --sentinel
