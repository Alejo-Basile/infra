#!/usr/bin/env bash
# lib/deps.sh — dependencias efímeras de integración QA (plan §5.3).
#
# Sourceable: no ejecuta nada al hacer source. `deps_up <servicio>` levanta un
# proyecto Compose propio (`qa-it-<servicio>-<run-id>`) con las dependencias que
# ese servicio necesita, publicadas solo en 127.0.0.1, y exporta las variables
# de conexión. `deps_down` destruye ese proyecto (volúmenes efímeros).
# shellcheck shell=bash

if [[ -n "${_QA_DEPS_SOURCED:-}" ]]; then
  return 0
fi
_QA_DEPS_SOURCED=1

_QA_DEPS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$_QA_DEPS_LIB_DIR/common.sh"

_deps_compute_ports() {
  local base="${QA_PORT_BASE:-27117}"
  QA_MONGO_PORT="${QA_MONGO_PORT:-$base}"
  QA_REDIS_PORT="${QA_REDIS_PORT:-$((base + 1))}"
  QA_MINIO_PORT="${QA_MINIO_PORT:-$((base + 2))}"
  QA_SENTINEL_PORT_1="${QA_SENTINEL_PORT_1:-$((base + 3))}"
  QA_SENTINEL_PORT_2="${QA_SENTINEL_PORT_2:-$((base + 4))}"
  QA_SENTINEL_PORT_3="${QA_SENTINEL_PORT_3:-$((base + 5))}"
  export QA_MONGO_PORT QA_REDIS_PORT QA_MINIO_PORT
  export QA_SENTINEL_PORT_1 QA_SENTINEL_PORT_2 QA_SENTINEL_PORT_3
}

# _deps_port_free PORT: 0 si nadie escucha en 127.0.0.1:PORT.
_deps_port_free() {
  local port="$1" out
  if command -v ss >/dev/null 2>&1; then
    out="$(ss -lntH 2>/dev/null || true)"
    ! printf '%s\n' "$out" | awk '{print $4}' | grep -qE "[:.]${port}$"
    return $?
  fi
  if command -v nc >/dev/null 2>&1; then
    ! nc -z 127.0.0.1 "$port" >/dev/null 2>&1
    return $?
  fi
  return 0
}

# _deps_id SERVICE: id del contenedor efímero (vacío si no existe).
_deps_id() {
  docker ps -a \
    --filter "label=com.docker.compose.project=${QA_IT_PROJECT}" \
    --filter "label=com.docker.compose.service=$1" \
    --format '{{.ID}}' 2>/dev/null | head -1
}

_deps_probe_health() {
  local id
  id="$(_deps_id "$1")"
  [[ -n "$id" ]] || return 1
  [[ "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)" == "healthy" ]]
}

_deps_probe_exit0() {
  local id
  id="$(_deps_id "$1")"
  [[ -n "$id" ]] || return 1
  [[ "$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || true)" == "exited" ]] &&
    [[ "$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null || true)" == "0" ]]
}

_deps_probe_sentinel() {
  local id
  id="$(_deps_id sentinel-1)"
  [[ -n "$id" ]] || return 1
  docker exec "$id" redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary 2>/dev/null | grep -q .
}

# _deps_wait_job DESC TIMEOUT CMD...: como _deps_wait, pero reintenta el job
# one-shot una vez (mongo-init/minio-init son idempotentes).
_deps_wait_job() {
  local desc="$1" timeout="$2" svc="$3"
  shift 3
  if qa_wait_for "$desc" "$timeout" "$@"; then
    return 0
  fi
  local id attempt
  id="$(_deps_id "$svc")"
  if [[ -n "$id" ]]; then
    for attempt in 1 2 3; do
      qa_log warn "$desc falló; reintento $attempt/3 en 3s"
      sleep 3
      docker start "$id" >/dev/null 2>&1 || true
      if qa_wait_for "$desc (reintento $attempt)" "$timeout" "$@"; then
        return 0
      fi
    done
  fi
  qa_log fail "job no completó: $desc"
  docker logs --tail=30 "$id" 2>&1 | qa_redact >&2 || true
  exit 4
}
_deps_wait() {
  local desc="$1" timeout="$2"
  shift 2
  if qa_wait_for "$desc" "$timeout" "$@"; then
    qa_log debug "listo: $desc"
    return 0
  fi
  qa_log fail "dependencia no disponible: $desc (timeout ${timeout}s)"
  qa_compose_test ps --all 2>/dev/null || true
  exit 4
}

deps_up() {
  local service="${1:?deps_up requiere un servicio}"
  # Compose exige proyecto en minúsculas [a-z0-9-_]; QA_RUN_ID trae una T.
  local project_slug
  project_slug="$(printf '%s' "$QA_RUN_ID" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')"
  QA_IT_PROJECT="qa-it-${service}-${project_slug}"
  export QA_IT_PROJECT

  _deps_compute_ports

  local base_ports=("$QA_MONGO_PORT" "$QA_REDIS_PORT" "$QA_MINIO_PORT")
  local needs_sentinel=0
  if [[ "$service" == "extraction-worker" || "$service" == "ocr-worker" ]]; then
    needs_sentinel=1
    base_ports+=("$QA_SENTINEL_PORT_1" "$QA_SENTINEL_PORT_2" "$QA_SENTINEL_PORT_3")
  fi

  local port
  for port in "${base_ports[@]}"; do
    if ! _deps_port_free "$port"; then
      qa_die 5 "puerto $port ocupado" "usa otro rango: QA_PORT_BASE=27217 qa.sh test $service --integration"
    fi
  done

  qa_compose_test config -q ||
    qa_die 3 "docker-compose.test.yml inválido" "revisa infra/compose/docker-compose.test.yml"

  qa_log info "deps: proyecto $QA_IT_PROJECT (mongo:$QA_MONGO_PORT redis:$QA_REDIS_PORT minio:$QA_MINIO_PORT)"
  qa_compose_test --profile core up -d mongo redis-streams redis-ratelimit minio mongo-init minio-init
  _deps_wait "mongo healthy" 60 _deps_probe_health mongo
  _deps_wait "redis-streams healthy" 30 _deps_probe_health redis-streams
  _deps_wait "redis-ratelimit healthy" 30 _deps_probe_health redis-ratelimit
  _deps_wait "minio healthy" 60 _deps_probe_health minio
  _deps_wait_job "mongo-init exit 0" 60 mongo-init _deps_probe_exit0 mongo-init
  _deps_wait_job "minio-init exit 0" 60 minio-init _deps_probe_exit0 minio-init

  if [[ $needs_sentinel -eq 1 ]]; then
    qa_compose_test --profile sentinel up -d \
      redis-streams-replica-1 redis-streams-replica-2 sentinel-1 sentinel-2 sentinel-3
    _deps_wait "sentinel responde myprimary" 90 _deps_probe_sentinel
  fi

  local streams_pw app_user worker_user root_user
  streams_pw="$(secret_value redis_streams_password.txt)"
  app_user="$(env_value MONGO_APP_USER docservice)"
  worker_user="$(env_value MONGO_WORKER_USER worker)"
  root_user="$(env_value MONGO_INITDB_ROOT_USERNAME root)"
  local enc_pw
  enc_pw="$(jq -rn --arg p "$streams_pw" '$p|@uri')"

  case "$service" in
    doc-service)
      export MONGO_TEST_URI="mongodb://${app_user}:$(secret_value mongo_app_password.txt)@127.0.0.1:${QA_MONGO_PORT}/?authSource=documents&directConnection=true"
      export REDIS_TEST_ADDR="127.0.0.1:${QA_REDIS_PORT}"
      export REDIS_TEST_PASSWORD="$streams_pw"
      export MINIO_TEST_ENDPOINT="127.0.0.1:${QA_MINIO_PORT}"
      export MINIO_TEST_PUBLIC_ENDPOINT="http://127.0.0.1:${QA_MINIO_PORT}"
      export MINIO_TEST_ACCESS_KEY
      export MINIO_TEST_SECRET_KEY
      MINIO_TEST_ACCESS_KEY="$(secret_value svc_docservice_access_key.txt)"
      MINIO_TEST_SECRET_KEY="$(secret_value svc_docservice_secret_key.txt)"
      ;;
    extraction-worker | ocr-worker)
      export REDIS_TEST_URL="redis://:${enc_pw}@127.0.0.1:${QA_REDIS_PORT}/"
      export REDIS_SENTINEL_ADDRS="127.0.0.1:${QA_SENTINEL_PORT_1},127.0.0.1:${QA_SENTINEL_PORT_2},127.0.0.1:${QA_SENTINEL_PORT_3}"
      export REDIS_MASTER_NAME="myprimary"
      export S3_ENDPOINT="http://127.0.0.1:${QA_MINIO_PORT}"
      export S3_ACCESS_KEY
      export S3_SECRET_KEY
      S3_ACCESS_KEY="$(secret_value svc_worker_access_key.txt)"
      S3_SECRET_KEY="$(secret_value svc_worker_secret_key.txt)"
      export MONGO_WORKER_URI="mongodb://${worker_user}:$(secret_value mongo_worker_password.txt)@127.0.0.1:${QA_MONGO_PORT}/documents?authSource=documents&directConnection=true"
      export MONGO_TEST_ROOT_URI="mongodb://${root_user}:$(secret_value mongo_initdb_root_password.txt)@127.0.0.1:${QA_MONGO_PORT}/?authSource=admin&directConnection=true"
      ;;
    *)
      qa_die 2 "servicio sin dependencias efímeras definidas: $service" \
        "destinos válidos: doc-service, extraction-worker, ocr-worker"
      ;;
  esac

  local envfile="$QA_RUN_DIR/deps.env"
  : >"$envfile"
  chmod 600 "$envfile"
  local var
  for var in MONGO_TEST_URI REDIS_TEST_ADDR REDIS_TEST_PASSWORD MINIO_TEST_ENDPOINT \
    MINIO_TEST_PUBLIC_ENDPOINT MINIO_TEST_ACCESS_KEY MINIO_TEST_SECRET_KEY \
    REDIS_TEST_URL REDIS_SENTINEL_ADDRS REDIS_MASTER_NAME S3_ENDPOINT S3_ACCESS_KEY \
    S3_SECRET_KEY MONGO_WORKER_URI MONGO_TEST_ROOT_URI; do
    if [[ -n "${!var:-}" ]]; then
      printf '%s=%s\n' "$var" "${!var}" >>"$envfile"
    fi
  done
  qa_log ok "deps listas (deps.env en $envfile; contiene credenciales de dev, modo 600)"
}

deps_down() {
  if [[ -z "${QA_IT_PROJECT:-}" ]]; then
    return 0
  fi
  if qa_truthy "${QA_KEEP_DEPS:-0}"; then
    qa_log info "QA_KEEP_DEPS=1: no se destruye $QA_IT_PROJECT"
    printf 'limpieza manual: docker compose -p %s down -v --remove-orphans\n' "$QA_IT_PROJECT"
    return 0
  fi
  # OJO: `down` con los `-f` del arnes es un no-op silencioso (exit 0 sin borrar
  # nada) y deja los contenedores ocupando los puertos 27117+. Sin `-f`, compose
  # resuelve el proyecto por su label y limpia de verdad.
  docker compose -p "$QA_IT_PROJECT" down -v --remove-orphans >/dev/null 2>&1 || true
  qa_log ok "deps destruidas (proyecto $QA_IT_PROJECT, volúmenes efímeros)"
}

deps_cleanup_stale() {
  docker compose ls --format json 2>/dev/null |
    jq -r '.[] | select(.Name | startswith("qa-it-")) | .Name' 2>/dev/null |
    while IFS= read -r project; do
      printf 'docker compose -p %s down -v --remove-orphans\n' "$project"
    done
}

deps_gate_summary() {
  printf 'project=%s mongo=%s redis=%s minio=%s s1=%s s2=%s s3=%s\n' \
    "${QA_IT_PROJECT:-}" "${QA_MONGO_PORT:-}" "${QA_REDIS_PORT:-}" "${QA_MINIO_PORT:-}" \
    "${QA_SENTINEL_PORT_1:-}" "${QA_SENTINEL_PORT_2:-}" "${QA_SENTINEL_PORT_3:-}"
}
