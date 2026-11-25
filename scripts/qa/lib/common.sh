#!/usr/bin/env bash
# lib/common.sh — contrato común de la automatización QA (plan §3.3).
#
# Este archivo se sourcea; no ejecuta acciones por sí solo. Expone:
#   qa_init, qa_compose, qa_compose_test, env_value, secret_value,
#   qa_log, qa_die, qa_wait_for, qa_require_tools, qa_trap_cleanup, qa_redact,
#   qa_http_code, qa_truthy, qa_doctor.
#
# Convenciones: comentarios en español, código en inglés (igual que
# infra/scripts). Nunca imprime el contenido de .env ni de infra/secrets/*.
# shellcheck shell=bash

if [[ -n "${_QA_COMMON_SOURCED:-}" ]]; then
  return 0
fi
_QA_COMMON_SOURCED=1

set -Eeuo pipefail

QA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
QA_SCRIPTS_DIR="$(cd "$QA_LIB_DIR/.." && pwd)"
INFRA_DIR="$(cd "$QA_SCRIPTS_DIR/../.." && pwd)"
WORKSPACE_ROOT="$(cd "$INFRA_DIR/.." && pwd)"

ENV_FILE="${QA_ENV_FILE:-$INFRA_DIR/.env}"
ENV_EXAMPLE="$INFRA_DIR/.env.example"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
BUILD_FILE="$INFRA_DIR/compose/docker-compose.build.yml"
TEST_FILE="$INFRA_DIR/compose/docker-compose.test.yml"
SECRETS_DIR="${QA_SECRETS_DIR:-$INFRA_DIR/secrets}"
CERT_DIR="$INFRA_DIR/traefik/certs"
MONGO_KEYFILE="$INFRA_DIR/compose/mongo/keyfile"

QA_PROJECT="${QA_PROJECT:-infra}"
QA_ARTIFACTS_DIR="${QA_ARTIFACTS_DIR:-$INFRA_DIR/.local/qa}"
QA_RUN_ID="${QA_RUN_ID:-$(date -u +%Y%m%dT%H%M%S)-$$}"
QA_RUN_DIR="$QA_ARTIFACTS_DIR/$QA_RUN_ID"
QA_LOG_LEVEL="${QA_LOG_LEVEL:-info}"
QA_SCRIPT_NAME="${QA_SCRIPT_NAME:-$(basename "${BASH_SOURCE[1]:-$0}" .sh)}"
QA_IT_PROJECT="${QA_IT_PROJECT:-}"
QA_PORT_BASE="${QA_PORT_BASE:-27117}"

# Claves de .env que compose exige con `:?` y que no pueden quedar en `changeme`.
QA_REQUIRED_ENV_KEYS=(
  MINIO_PUBLIC_ENDPOINT
  MINIO_WEBHOOK_SECRET
  INTERNAL_TOKEN
  MONGO_APP_USER
  MONGO_APP_PASSWORD
  MONGO_WORKER_USER
  MONGO_WORKER_PASSWORD
  CONSUL_IMAGE_TAG
  REDIS_STREAM_KEY
)

# Archivos exigidos por el bloque `secrets:` de docker-compose.yml (29) más el
# keyfile de Mongo y los certificados de Consul usados por los servicios.
QA_REQUIRED_SECRETS=(
  mongo_initdb_root_password.txt
  mongo_app_password.txt
  mongo_worker_password.txt
  redis_streams_password.txt
  redis_streams_password.json
  redis_ratelimit_password.txt
  minio_root_password.txt
  minio_webhook_secret.txt
  internal_token.txt
  grafana_admin_password.txt
  svc_docservice_access_key.txt
  svc_docservice_secret_key.txt
  svc_worker_access_key.txt
  svc_worker_secret_key.txt
  ocr_minio_access_key.txt
  ocr_minio_secret_key.txt
  ocr_mongo_password.txt
  consul_gossip_key.txt
  consul_server_cert.pem
  consul_server_key.pem
  consul_ca_cert.pem
  consul_operator_token.txt
  consul_doc_service_token.txt
  consul_ratelimitd_token.txt
  consul_worker_token.txt
  consul_ocr_worker_token.txt
  consul_prometheus_token.txt
  consul_ui_password.txt
  consul_ui_users.txt
)

# ---------------------------------------------------------------------------
# Inicialización y diagnóstico
# ---------------------------------------------------------------------------

# qa_init: valida el workspace y prepara el directorio de artefactos.
# Falla con código 2 si el layout multi-repo no resuelve.
qa_init() {
  local path
  for path in \
    "$COMPOSE_FILE" \
    "$INFRA_DIR/.env.example" \
    "$WORKSPACE_ROOT/doc-service" \
    "$WORKSPACE_ROOT/extraction-worker" \
    "$WORKSPACE_ROOT/platform-services"; do
    if [[ ! -e "$path" ]]; then
      qa_die 2 "workspace inválido: falta $path" \
        "ejecuta desde el workspace multi-repo que contiene infra/, doc-service/, extraction-worker/ y platform-services/"
    fi
  done

  umask 077
  mkdir -p "$QA_RUN_DIR"
  chmod 700 "$QA_ARTIFACTS_DIR" "$QA_RUN_DIR" 2>/dev/null || true
}

# qa_script_path: ruta absoluta de un script hermano de qa/.
qa_script_path() {
  printf '%s/%s' "$QA_SCRIPTS_DIR" "$1"
}

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------

# qa_compose: compose del entorno de desarrollo (proyecto QA_PROJECT).
qa_compose() {
  docker compose \
    -f "$COMPOSE_FILE" \
    -f "$BUILD_FILE" \
    --env-file "$ENV_FILE" \
    -p "$QA_PROJECT" \
    "$@"
}

# qa_compose_test: compose efímero de integración (proyecto QA_IT_PROJECT).
# deps.sh define QA_IT_PROJECT antes de llamar.
qa_compose_test() {
  if [[ -z "$QA_IT_PROJECT" ]]; then
    qa_die 2 "QA_IT_PROJECT no definido" \
      "lib/deps.sh debe calcular el proyecto efímero antes de llamar a qa_compose_test"
  fi
  docker compose \
    -f "$COMPOSE_FILE" \
    -f "$BUILD_FILE" \
    -f "$TEST_FILE" \
    --env-file "$ENV_FILE" \
    -p "$QA_IT_PROJECT" \
    "$@"
}

# ---------------------------------------------------------------------------
# Lectura de configuración y secretos
# ---------------------------------------------------------------------------

# env_value KEY [default]: lee .env sin exportar ni imprimir valores ajenos.
env_value() {
  local key="$1" default="${2:-}" value
  if [[ ! -r "$ENV_FILE" ]]; then
    printf '%s' "$default"
    return 0
  fi
  value="$(awk -v k="$key" '
    index($0, k "=") == 1 { value = substr($0, length(k) + 2) }
    END { printf "%s", value }
  ' "$ENV_FILE")"
  printf '%s' "${value:-$default}"
}

# secret_value FILE: contenido de infra/secrets/FILE sin newline final.
# Falla con código 3 si no existe o está vacío. Nunca se loguea.
secret_value() {
  local file="$1" path="$SECRETS_DIR/$1" value
  if [[ ! -r "$path" ]]; then
    qa_die 3 "secreto faltante: $file" \
      "./$(basename "$0") up --init-secrets  # o coloca $path"
  fi
  value="$(cat "$path")"
  if [[ -z "${value//[[:space:]]/}" ]]; then
    qa_die 3 "secreto vacío: $file" "regenera $path (nunca se imprime su contenido)"
  fi
  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

# qa_log LEVEL MSG: [INFO]/[OK]/[WARN] a stdout, [FAIL]/[DEBUG] según nivel.
qa_log() {
  local level="$1"
  shift
  local tag
  case "$level" in
    ok) tag="OK" ;;
    warn) tag="WARN" ;;
    fail) tag="FAIL" ;;
    debug)
      [[ "$QA_LOG_LEVEL" == "debug" ]] || return 0
      tag="DEBUG"
      ;;
    *) tag="INFO" ;;
  esac
  local line="[$tag] $QA_SCRIPT_NAME · $*"
  if [[ "$level" == "fail" ]]; then
    printf '%s\n' "$line" >&2
  else
    printf '%s\n' "$line"
  fi
}

# qa_die CODE MSG HINT: mensaje accionable + exit.
qa_die() {
  local code="$1" msg="$2" hint="${3:-}"
  printf '[FAIL] %s · %s\n' "$QA_SCRIPT_NAME" "$msg" >&2
  if [[ -n "$hint" ]]; then
    printf '       accion: %s\n' "$hint" >&2
  fi
  exit "$code"
}

# qa_debug MSG: solo con QA_LOG_LEVEL=debug.
qa_debug() { qa_log debug "$@"; }

# ---------------------------------------------------------------------------
# Utilidades de ejecución
# ---------------------------------------------------------------------------

# qa_truthy VALUE: 1/true/yes/on → 0; 0/false/no/off/"" → 1.
qa_truthy() {
  case "${1:-}" in
    1 | true | TRUE | yes | YES | on | ON) return 0 ;;
    *) return 1 ;;
  esac
}

# qa_wait_for DESC TIMEOUT CMD...
# Reintenta cada segundo hasta el timeout. Devuelve 0/1; no imprime.
qa_wait_for() {
  local desc="$1" timeout="$2"
  shift 2
  local deadline=$((SECONDS + timeout))
  qa_log debug "esperando: $desc (timeout ${timeout}s)"
  while :; do
    if "$@" >/dev/null 2>&1; then
      return 0
    fi
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 1
  done
}

# qa_require_tools NAME...: preflight de binarios con hint de instalación.
qa_require_tools() {
  local missing=() tool hint
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if ((${#missing[@]} > 0)); then
    for tool in "${missing[@]}"; do
      case "$tool" in
        docker) hint="https://docs.docker.com/engine/install/" ;;
        jq) hint="https://jqlang.github.io/jq/download/" ;;
        curl) hint="instala curl con el gestor de paquetes de tu SO" ;;
        openssl) hint="instala openssl (libssl / openssl-devel) con el gestor de paquetes" ;;
        shellcheck) hint="https://github.com/koalaman/shellcheck#installing" ;;
        yamllint) hint="pip install --user yamllint" ;;
        yq) hint="https://github.com/mikefarah/yq#install" ;;
        gcc) hint="instala build-essential (go test -race lo necesita)" ;;
        mkcert) hint="https://github.com/FiloSottile/mkcert#installation" ;;
        nc) hint="instala netcat-openbsd" ;;
        ss) hint="instala iproute2" ;;
        go) hint="https://go.dev/doc/install (versión en doc-service/go.mod)" ;;
        cargo) hint="https://rustup.rs (canal en extraction-worker/rust-toolchain.toml)" ;;
        python3) hint="instala python3 con el gestor de paquetes de tu SO" ;;
        k6) hint="https://grafana.com/docs/k6/latest/set-up/install-k6/" ;;
        *) hint="instala '$tool' con el gestor de paquetes de tu SO" ;;
      esac
      printf '[FAIL] %s · falta la herramienta: %s\n       accion: %s\n' \
        "$QA_SCRIPT_NAME" "$tool" "$hint" >&2
    done
    exit 2
  fi
  if ! docker compose version >/dev/null 2>&1; then
    qa_die 2 "falta el plugin 'docker compose' v2" "https://docs.docker.com/compose/install/linux/"
  fi
}

# qa_trap_cleanup FN: registra FN(rc) en EXIT, INT y TERM preservando el código.
qa_trap_cleanup() {
  _QA_CLEANUP_FN="$1"
  trap '_qa_rc=$?; if [[ -n "${_QA_CLEANUP_FN:-}" ]]; then "$_QA_CLEANUP_FN" "$_qa_rc" || true; fi; exit "$_qa_rc"' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
}

# qa_http_code URL [extra curl args...]: código HTTP o 000 si no conecta.
qa_http_code() {
  local url="$1"
  shift || true
  curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "$@" "$url" 2>/dev/null || printf '000'
}

# qa_redact: filtra secretos de cualquier log persistido (stdin → stdout).
qa_redact() {
  sed -E \
    -e 's#(://[^:/@[:space:]]+):[^@/[:space:]]+@#\1:***@#g' \
    -e 's/((PASSWORD|PASSWD|TOKEN|SECRET|APIKEY|API_KEY)[A-Za-z0-9_]*[[:space:]]*[=:][[:space:]]*)[^[:space:],;\"]+/\1***REDACTED***/Ig' \
    -e 's/((signature|X-Amz-[A-Za-z-]+|x-amz-[a-z-]+)[[:space:]]*[=:][[:space:]]*)[^[:space:],;&\"]+/\1***REDACTED***/Ig' \
    -e 's/((policy|credential)[[:space:]]*[=:][[:space:]]*)[^[:space:],;&\"]+/\1***REDACTED***/Ig'
}

# qa_truncate_file FILE MAX_BYTES: trunca con aviso explícito (nunca silencioso).
qa_truncate_file() {
  local file="$1" max="${2:-5242880}" size
  [[ -f "$file" ]] || return 0
  size="$(wc -c <"$file")"
  if ((size > max)); then
    printf '\n[WARN] log truncado: %s bytes > %s (se conservan los primeros %s)\n' \
      "$size" "$max" "$max" >>"$file"
    head -c "$max" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
  fi
}

# ---------------------------------------------------------------------------
# Doctor: diagnóstico de solo lectura del entorno
# ---------------------------------------------------------------------------

qa_doctor() {
  local fail=0 key value file
  printf '[INFO] %s · doctor\n' "$QA_SCRIPT_NAME"

  for key in docker jq curl; do
    if command -v "$key" >/dev/null 2>&1; then
      printf '  [OK]    herramienta %-10s %s\n' "$key" "$(command -v "$key")"
    else
      printf '  [FALTA] herramienta %-10s\n' "$key"
      fail=$((fail + 1))
    fi
  done
  if command -v openssl >/dev/null 2>&1; then
    printf '  [OK]    herramienta %-10s %s\n' openssl "$(command -v openssl)"
  else
    printf '  [WARN]  herramienta %-10s ausente: solo se necesita para --init-secrets\n' openssl
  fi

  if [[ -f "$ENV_FILE" ]]; then
    printf '  [OK]    .env presente (%s)\n' "$ENV_FILE"
    local placeholders=()
    for key in "${QA_REQUIRED_ENV_KEYS[@]}"; do
      value="$(env_value "$key")"
      if [[ -z "$value" || "$value" == *changeme* ]]; then
        placeholders+=("$key")
      fi
    done
    if ((${#placeholders[@]} > 0)); then
      printf '  [FALTA] claves de .env sin completar: %s\n' "${placeholders[*]}"
      fail=$((fail + 1))
    else
      printf '  [OK]    .env sin placeholders en claves obligatorias\n'
    fi
  else
    printf '  [FALTA] .env no existe (copia %s)\n' "$ENV_EXAMPLE"
    fail=$((fail + 1))
  fi

  local missing_secrets=()
  for file in "${QA_REQUIRED_SECRETS[@]}"; do
    [[ -r "$SECRETS_DIR/$file" ]] || missing_secrets+=("$file")
  done
  # El keyfile lo lee el daemon de Docker (root), no este usuario: basta con
  # que exista y no esté vacío.
  [[ -s "$MONGO_KEYFILE" ]] || missing_secrets+=("compose/mongo/keyfile")
  if ((${#missing_secrets[@]} > 0)); then
    printf '  [FALTA] %d secreto(s): %s\n' "${#missing_secrets[@]}" "${missing_secrets[*]}"
    fail=$((fail + 1))
  else
    printf '  [OK]    secretos: %d/%d presentes\n' \
      "$((${#QA_REQUIRED_SECRETS[@]} + 1))" "$((${#QA_REQUIRED_SECRETS[@]} + 1))"
  fi

  if [[ -f "$CERT_DIR/api.localhost.pem" && -f "$CERT_DIR/s3.localhost.pem" ]]; then
    printf '  [OK]    certificados api.localhost y s3.localhost\n'
  else
    printf '  [FALTA] certificados en %s (ejecuta infra/scripts/gen-certs.sh)\n' "$CERT_DIR"
    fail=$((fail + 1))
  fi

  if docker compose -f "$COMPOSE_FILE" -f "$BUILD_FILE" --env-file "$ENV_FILE" \
    -p "$QA_PROJECT" config -q >/dev/null 2>&1; then
    printf '  [OK]    docker compose config válido\n'
  else
    printf '  [FALTA] docker compose config inválido para el proyecto %s\n' "$QA_PROJECT"
    fail=$((fail + 1))
  fi

  if ((fail == 0)); then
    qa_log ok "doctor: entorno listo"
    return 0
  fi
  qa_log warn "doctor: $fail problema(s); corrige los [FALTA] y re-ejecuta"
  return 3
}
