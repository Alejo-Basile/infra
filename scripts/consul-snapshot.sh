#!/bin/sh
# infra/scripts/consul-snapshot.sh
# Contrato snapshot/restore para Consul (S11).
# Subcomandos: save, inspect, restore --yes, --help.
# Exit codes: 0 ok, 1 fallo operativo, 2 error de uso (incluye restore sin --yes).
#
# Resolucion del binario consul:
#   - si `consul` esta en PATH, se usa directamente.
#   - si no, se ejecuta la imagen fijada (CONSUL_IMAGE_TAG, default 1.22.7)
#     via `docker run --rm` reutilizando el mismo CONSUL_HTTP_ADDR.
#   - si el host de la direccion no es 127.0.0.1/localhost, el contenedor CLI
#     corre en la red compose (infra_internal) para resolver el nombre del servicio.
#
# Seguridad: nunca se imprime el token completo (prefijo de 8 chars max).
set -eu

CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-https://127.0.0.1:8501}"
CONSUL_IMAGE_TAG="${CONSUL_IMAGE_TAG:-1.22.7}"
CONSUL_CACERT="${CONSUL_CACERT:-}"

usage() {
  cat <<EOF
Uso: $0 <save|inspect|restore> [opciones]

Subcomandos:
  save [--out ARCHIVO]           Crea un snapshot bajo infra/docs/evidencias/S11/ (o --out).
  inspect ARCHIVO                Muestra tamano, indice Raft, peers y version.
  restore --yes ARCHIVO          Restaura el snapshot (requiere --yes, exit 2 sin el).

Opciones:
  --out ARCHIVO                  Destino del snapshot (solo save).
  --yes                          Confirmacion explicita para restore.
  --force-real-target            Permite restore contra host 'consul' (volumen real).
  --help                         Muestra esta ayuda.

Variables de entorno:
  CONSUL_HTTP_ADDR                (default https://127.0.0.1:8501)
  CONSUL_HTTP_TOKEN / CONSUL_HTTP_TOKEN_FILE / CONSUL_OPERATOR_TOKEN_FILE
  CONSUL_CACERT
  CONSUL_IMAGE_TAG               (default 1.22.7)
EOF
}

# Token
resolve_token() {
  if [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
    printf '%s' "$CONSUL_HTTP_TOKEN"
    return
  fi
  for f in "${CONSUL_HTTP_TOKEN_FILE:-}" "${CONSUL_OPERATOR_TOKEN_FILE:-}"; do
    if [ -n "$f" ] && [ -r "$f" ]; then
      tr -d '\n' < "$f"
      return
    fi
  done
  # default secret path
  if [ -r "infra/secrets/consul_operator_token.txt" ]; then
    tr -d '\n' < "infra/secrets/consul_operator_token.txt"
    return
  fi
  if [ -r "/run/secrets/consul_operator_token" ]; then
    tr -d '\n' < "/run/secrets/consul_operator_token"
    return
  fi
  return 1
}

# host of address
addr_host() {
  # strip scheme
  h="${1#*://}"
  h="${h%%/*}"
  h="${h%%:*}"
  printf '%s' "$h"
}

# build consul invocation
consul_exec() {
  # args passed to consul
  if command -v consul >/dev/null 2>&1; then
    consul "$@"
    return
  fi
  host="$(addr_host "$CONSUL_HTTP_ADDR")"
  case "$host" in
    127.0.0.1|localhost)
      net="--network host"
      ;;
    *)
      net="--network infra_internal"
      ;;
  esac
  # shellcheck disable=SC2086
  docker run --rm $net \
    -e CONSUL_HTTP_ADDR="$CONSUL_HTTP_ADDR" \
    -e CONSUL_HTTP_TOKEN="$TOKEN" \
    ${CONSUL_CACERT:+-e CONSUL_CACERT="$CONSUL_CACERT"} \
    "hashicorp/consul:$CONSUL_IMAGE_TAG" \
    consul "$@"
}

TOKEN=""
TOKEN="$(resolve_token)" || { echo "FAIL: no se pudo resolver token de operador" >&2; exit 1; }
TPREFIX="$(printf '%s' "$TOKEN" | cut -c1-8)"
echo "INFO: token prefix=$TPREFIX..."

cmd="${1:-}"
shift 2>/dev/null || true

case "$cmd" in
  --help|-h|help|"")
    usage
    exit 0
    ;;
esac

case "$cmd" in
  save)
    out=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --out) out="$2"; shift 2;;
        *) echo "ERROR: opcion desconocida $1" >&2; exit 2;;
      esac
    done
    if [ -z "$out" ]; then
      ts="$(date -u +%Y%m%dT%H%M%SZ)"
      out="infra/docs/evidencias/S11/S11-P1-C26-${ts}.snap"
    fi
    mkdir -p "$(dirname "$out")"
    # env for consul
    export CONSUL_HTTP_ADDR CONSUL_HTTP_TOKEN="$TOKEN"
    [ -n "$CONSUL_CACERT" ] && export CONSUL_CACERT
    consul_exec snapshot save "$out"
    sz="$(stat -c%s "$out" 2>/dev/null || stat -f%z "$out")"
    echo "OK: snapshot guardado en $out ($sz bytes)"
    ;;
  inspect)
    file="${1:-}"
    if [ -z "$file" ]; then echo "ERROR: falta ARCHIVO" >&2; exit 2; fi
    export CONSUL_HTTP_ADDR CONSUL_HTTP_TOKEN="$TOKEN"
    [ -n "$CONSUL_CACERT" ] && export CONSUL_CACERT
    ls -l "$file"
    consul_exec snapshot inspect "$file"
    ;;
  restore)
    yes=0
    force=0
    file=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --yes) yes=1; shift;;
        --force-real-target) force=1; shift;;
        *) 
          if [ -z "$file" ]; then file="$1"; shift; else echo "ERROR: argumento inesperado $1" >&2; exit 2; fi
          ;;
      esac
    done
    if [ "$yes" -ne 1 ]; then
      echo "ERROR: restore requiere confirmacion explicita --yes (exit 2)" >&2
      exit 2
    fi
    if [ -z "$file" ]; then echo "ERROR: falta ARCHIVO" >&2; exit 2; fi
    host="$(addr_host "$CONSUL_HTTP_ADDR")"
    if [ "$host" = "consul" ] && [ "$force" -ne 1 ]; then
      echo "WARNING: destino es el server real 'consul' (volumen consul-data). Riesgo de perdida. Pasa --force-real-target para continuar." >&2
      exit 1
    fi
    echo "INFO: restore hacia CONSUL_HTTP_ADDR=$CONSUL_HTTP_ADDR"
    export CONSUL_HTTP_ADDR CONSUL_HTTP_TOKEN="$TOKEN"
    [ -n "$CONSUL_CACERT" ] && export CONSUL_CACERT
    consul_exec snapshot restore "$file"
    echo "OK: restore completado"
    ;;
  *)
    echo "ERROR: subcomando desconocido: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
exit 0
EOF
echo written