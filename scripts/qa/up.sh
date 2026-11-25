#!/usr/bin/env bash
# up.sh — levanta el entorno QA con verificación de salud real (plan §4).
#
# Orden estricto: preflight -> workspace -> daemon -> .env -> secretos ->
# certificados -> compose config -> up -d -> gates -> post-checks -> resumen.
# Nunca ejecuta `down`, nunca borra volúmenes ni secretos existentes.
set -Eeuo pipefail

QA_SCRIPT_NAME="qa/up"
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROFILE="full"
PROFILES=()
BUILD=0
INIT_SECRETS=0
NO_INIT=0
TIMEOUT=240
NO_WAIT=0
DRY_RUN=0
HTTPS_PORT=""

GATE_NAMES=()
GATE_STATUSES=()
GATE_DURATIONS=()
GATE_DETAILS=()
START_EPOCH=0

# write_up_json: persiste el resultado de los gates en $QA_RUN_DIR/up.json.
write_up_json() {
  local gates_json="[]" i
  for i in "${!GATE_NAMES[@]}"; do
    gates_json="$(printf '%s' "$gates_json" | jq \
      --arg name "${GATE_NAMES[$i]}" \
      --arg status "${GATE_STATUSES[$i]}" \
      --argjson duration_s "${GATE_DURATIONS[$i]:-0}" \
      --arg detail "${GATE_DETAILS[$i]}" \
      '. + [{name:$name,status:$status,duration_s:$duration_s,detail:$detail}]')"
  done
  jq -n \
    --arg run_id "$QA_RUN_ID" \
    --arg profile "$(IFS=,; echo "${PROFILES[*]}")" \
    --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson duration_s "$((SECONDS - START_EPOCH))" \
    --argjson dry_run "$([[ $DRY_RUN -eq 1 ]] && echo true || echo false)" \
    --argjson gates "$gates_json" \
    '{run_id:$run_id,profile:$profile,started_at:$started_at,duration_s:$duration_s,dry_run:$dry_run,gates:$gates}' \
    >"$QA_RUN_DIR/up.json"
}

usage() {
  cat <<'EOF'
Uso: qa.sh up [opciones]

  --profile core|full|discovery|sentinel|all   perfil(es) a levantar (default full + sentinel)
  --build                                      reconstruye doc-service:local
  --init-secrets                               genera SOLO secretos faltantes de dev
  --no-init                                    no crea .env faltante
  --timeout <segundos>                         timeout global de salud (default 240)
  --no-wait                                    levanta sin esperar gates
  --dry-run                                    imprime lo que haría

Nota: full implica sentinel porque doc-service resuelve Redis por Sentinel.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || qa_die 2 "--profile requiere un valor" "core|full|discovery|sentinel|all"
      PROFILE="$2"
      case "$2" in
        all) PROFILES=(core full discovery sentinel chaos) ;;
        core | full | discovery | sentinel | chaos) PROFILES+=("$2") ;;
        *) qa_die 2 "perfil inválido: $2" "usa core|full|discovery|sentinel|all" ;;
      esac
      shift 2
      ;;
    --build) BUILD=1; shift ;;
    --init-secrets) INIT_SECRETS=1; shift ;;
    --no-init) NO_INIT=1; shift ;;
    --timeout)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || qa_die 2 "--timeout requiere segundos" "--timeout 240"
      TIMEOUT="$2"
      shift 2
      ;;
    --no-wait) NO_WAIT=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) qa_die 2 "opción desconocida: $1" "ejecuta qa.sh up --help" ;;
  esac
done

if ((${#PROFILES[@]} == 0)); then
  PROFILES=("$PROFILE")
fi

# full (y all) implican sentinel: doc-service resuelve Redis Sentinel.
_has_profile() { local p; for p in "${PROFILES[@]}"; do [[ "$p" == "$1" ]] && return 0; done; return 1; }
if _has_profile full || _has_profile all; then
  _found=0
  for p in "${PROFILES[@]}"; do [[ "$p" == "sentinel" ]] && _found=1; done
  [[ $_found -eq 0 ]] && PROFILES+=(sentinel)
fi

# has_profile P: 0 si el perfil está activo.
has_profile() {
  local p
  for p in "${PROFILES[@]}"; do
    [[ "$p" == "$1" ]] && return 0
  done
  return 1
}

record_gate() {
  GATE_NAMES+=("$1")
  GATE_STATUSES+=("$2")
  GATE_DURATIONS+=("$3")
  GATE_DETAILS+=("${4:-}")
}

# run CMD...: ejecuta, o imprime en --dry-run.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    qa_log info "[dry-run] $*"
    return 0
  fi
  "$@"
}

# effective_timeout WANT: min(WANT, restante del timeout global).
effective_timeout() {
  local want="$1" remaining=$((DEADLINE - SECONDS))
  ((remaining < 1)) && remaining=1
  ((want < remaining)) && printf '%s' "$want" || printf '%s' "$remaining"
}

dump_failure() {
  local svc="$1"
  qa_log fail "gate de salud vencido: $svc"
  qa_compose ps --all || true
  if [[ -n "$svc" ]] && qa_compose ps -aq "$svc" >/dev/null 2>&1; then
    qa_log info "últimas 30 líneas de $svc (redactadas):"
    qa_compose logs --no-color --tail=30 "$svc" 2>&1 | qa_redact >&2 || true
  fi
  write_up_json
  exit 4
}

run_gate() {
  local retry=0
  if [[ "${1:-}" == "--retry" ]]; then
    retry=1
    shift
  fi
  local name="$1" timeout="$2" svc="$3"
  shift 3
  local start=$SECONDS t
  if [[ $NO_WAIT -eq 1 || $DRY_RUN -eq 1 ]]; then
    record_gate "$name" skip 0 "sin espera"
    return 0
  fi
  t="$(effective_timeout "$timeout")"
  if qa_wait_for "$name" "$t" "$@"; then
    record_gate "$name" pass $((SECONDS - start)) ""
    qa_log ok "$name"
    return 0
  fi
  # Los jobs one-shot (mongo-init/minio-init/minio-notify-init) son
  # idempotentes: un segundo arranque cubre fallos transitorios de IAM/red.
  if [[ $retry -eq 1 ]]; then
    local id attempt
    id="$(_service_id "$svc")"
    if [[ -n "$id" ]]; then
      for attempt in 1 2 3; do
        qa_log warn "$name falló; reintento $attempt/3 en 3s"
        sleep 3
        docker start "$id" >/dev/null 2>&1 || true
        if qa_wait_for "$name (reintento $attempt)" "$(effective_timeout "$timeout")" "$@"; then
          record_gate "$name" pass $((SECONDS - start)) "reintento $attempt"
          qa_log ok "$name (reintento $attempt)"
          return 0
        fi
      done
    fi
  fi
  record_gate "$name" fail $((SECONDS - start)) "timeout ${t}s"
  dump_failure "$svc"
}

# --- Probes -----------------------------------------------------------------

# -a incluye jobs one-shot ya terminados (mongo-init/minio-init), que es
# justamente lo que hay que inspeccionar para verificar exit 0.
_service_id() { qa_compose ps -aq "$1" 2>/dev/null | head -1; }

_probe_health() {
  local id
  id="$(_service_id "$1")"
  [[ -n "$id" ]] || return 1
  local value
  value="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)"
  [[ "$value" == "healthy" || "$value" == "running" ]]
}

# El healthcheck de Mongo solo prueba que mongod acepta conexiones; la app
# necesita ademas que el nodo sea primario del replica set rs0.
_probe_mongo_primary() {
  local id
  id="$(_service_id mongo)"
  [[ -n "$id" ]] || return 1
  docker exec "$id" sh -c \
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$(cat /run/secrets/mongo_initdb_root_password)" --authenticationDatabase admin --eval "db.hello().isWritablePrimary"' \
    2>/dev/null | grep -qx true
}

_probe_exit0() {
  local id status code
  id="$(_service_id "$1")"
  [[ -n "$id" ]] || return 1
  status="$(docker inspect -f '{{.State.Status}}' "$id" 2>/dev/null || true)"
  code="$(docker inspect -f '{{.State.ExitCode}}' "$id" 2>/dev/null || true)"
  [[ "$status" == "exited" && "$code" == "0" ]]
}

_probe_wget() {
  local id
  id="$(_service_id "$1")"
  [[ -n "$id" ]] || return 1
  docker exec "$id" wget -qO- "http://localhost:$2$3" >/dev/null 2>&1
}

_probe_curl() {
  local id
  id="$(_service_id "$1")"
  [[ -n "$id" ]] || return 1
  docker exec "$id" curl -fsS "http://localhost:$2$3" >/dev/null 2>&1
}

_probe_http() {
  local code
  code="$(qa_http_code "$1")"
  [[ "$code" =~ $2 ]]
}

_probe_stream() {
  local id pw key
  id="$(_service_id redis-streams)"
  [[ -n "$id" ]] || return 1
  pw="$(cat "$SECRETS_DIR/redis_streams_password.txt" 2>/dev/null || true)"
  [[ -n "$pw" ]] || return 1
  key="$(env_value REDIS_STREAM_KEY "stream:pdf-processing")"
  docker exec "$id" redis-cli -a "$pw" --no-auth-warning XLEN "$key" >/dev/null 2>&1
}

_probe_sentinel_master() {
  local id out
  id="$(_service_id sentinel-1)"
  [[ -n "$id" ]] || return 1
  out="$(docker exec "$id" redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary 2>/dev/null | head -2 | paste -sd: -)"
  [[ "$out" =~ ^[^:]+:[0-9]+$ ]]
}

# --- 1. Preflight -------------------------------------------------------------

tools=(docker curl jq)
if [[ $INIT_SECRETS -eq 1 ]]; then
  tools+=(openssl)
fi
qa_require_tools "${tools[@]}"

if ! timeout 10 docker info >/dev/null 2>&1; then
  qa_die 5 "el daemon de Docker no responde" \
    "systemctl start docker (Linux) o abre Docker Desktop y reintenta"
fi

# --- 2. Workspace -------------------------------------------------------------

qa_init
qa_log info "workspace=$WORKSPACE_ROOT · perfil=$(IFS=,; echo "${PROFILES[*]}") · run=$QA_RUN_ID"

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT 443)"
export HTTPS_PORT

# --- 3. .env ------------------------------------------------------------------

if [[ ! -f "$ENV_FILE" ]]; then
  if [[ $NO_INIT -eq 1 ]]; then
    qa_die 3 ".env ausente y --no-init activo" "copia $ENV_EXAMPLE a $ENV_FILE y completa las claves"
  fi
  run cp "$ENV_EXAMPLE" "$ENV_FILE"
  run chmod 600 "$ENV_FILE"
  qa_log warn ".env creado desde .env.example; completa los valores marcados como changeme"
fi

missing_keys=()
if [[ -f "$ENV_FILE" ]]; then
  for key in "${QA_REQUIRED_ENV_KEYS[@]}"; do
    value="$(env_value "$key")"
    if [[ -z "$value" || "$value" == *changeme* ]]; then
      missing_keys+=("$key")
    fi
  done
fi

if ((${#missing_keys[@]} > 0)); then
  if [[ $INIT_SECRETS -eq 0 ]]; then
    qa_die 3 "claves de .env sin completar: ${missing_keys[*]}" \
      "qa.sh up --init-secrets  # o completa $ENV_FILE a mano"
  fi
  for key in "${missing_keys[@]}"; do
    case "$key" in
      MINIO_PUBLIC_ENDPOINT) new_value="https://s3.localhost:$HTTPS_PORT" ;;
      MONGO_APP_USER) new_value="docservice" ;;
      MONGO_WORKER_USER) new_value="worker" ;;
      REDIS_STREAM_KEY) new_value="stream:pdf-processing" ;;
      CONSUL_IMAGE_TAG) new_value="1.22.7" ;;
      *) new_value="$(openssl rand -hex 24)" ;;
    esac
    if [[ $DRY_RUN -eq 1 ]]; then
      qa_log info "[dry-run] completaría $key en .env"
      continue
    fi
    tmp_env="$(mktemp "$ENV_FILE.XXXXXX")"
    chmod 600 "$tmp_env"
    awk -v k="$key" -v v="$new_value" '
      BEGIN { done = 0 }
      index($0, k "=") == 1 { print k "=" v; done = 1; next }
      { print }
      END { if (!done) print k "=" v }
    ' "$ENV_FILE" >"$tmp_env"
    mv "$tmp_env" "$ENV_FILE"
  done
fi
if [[ $DRY_RUN -eq 0 ]]; then
  qa_log ok ".env: claves obligatorias completas"
fi

# --- 4. Secretos --------------------------------------------------------------

missing_secrets=()
for file in "${QA_REQUIRED_SECRETS[@]}"; do
  [[ -r "$SECRETS_DIR/$file" ]] || missing_secrets+=("$file")
done
# El keyfile de Mongo lo lee el daemon (root): existe y no está vacío.
[[ -s "$MONGO_KEYFILE" ]] || missing_secrets+=("compose/mongo/keyfile")

if ((${#missing_secrets[@]} > 0)); then
  if [[ $INIT_SECRETS -eq 0 ]]; then
    qa_die 3 "secretos faltantes (${#missing_secrets[@]}): ${missing_secrets[*]}" \
      "qa.sh up --init-secrets  # genera secretos de desarrollo, nunca de producción"
  fi
  qa_log warn "generando secretos de DESARROLLO; nunca uses estos valores en producción"
  if [[ $DRY_RUN -eq 1 ]]; then
    qa_log info "[dry-run] generaría: ${missing_secrets[*]}"
  else
    umask 077
    mkdir -p "$SECRETS_DIR" "$(dirname "$MONGO_KEYFILE")"

    ensure_secret() {
      local name="$1" path="$SECRETS_DIR/$1"
      [[ -s "$path" ]] && return 0
      openssl rand -base64 36 | tr -d '\n' >"$path"
      chmod 400 "$path"
    }

    wants_consul_certs=0
    for file in "${missing_secrets[@]}"; do
      case "$file" in
        consul_server_cert.pem | consul_server_key.pem | consul_ca_cert.pem)
          wants_consul_certs=1
          ;;
        compose/mongo/keyfile)
          [[ -s "$MONGO_KEYFILE" ]] || {
            openssl rand -base64 756 | tr -d '\n' >"$MONGO_KEYFILE"
            chmod 400 "$MONGO_KEYFILE"
          }
          ;;
        redis_streams_password.json)
          ensure_secret redis_streams_password.txt
          pw_json="$(cat "$SECRETS_DIR/redis_streams_password.txt")"
          printf '{"redis://redis-streams:6379": "%s"}\n' "$pw_json" >"$SECRETS_DIR/$file"
          chmod 400 "$SECRETS_DIR/$file"
          ;;
        *) ensure_secret "$file" ;;
      esac
    done

    if [[ $wants_consul_certs -eq 1 ]]; then
      CA_KEY="$SECRETS_DIR/consul_ca_key.pem"
      CA_CERT="$SECRETS_DIR/consul_ca_cert.pem"
      SRV_KEY="$SECRETS_DIR/consul_server_key.pem"
      SRV_CERT="$SECRETS_DIR/consul_server_cert.pem"
      SAN_CONF="$(mktemp /tmp/qa-consul-san.XXXXXX)"
      printf 'subjectAltName=DNS:consul,DNS:consul-agent,DNS:consul.localhost\n' >"$SAN_CONF"
      if [[ ! -s "$CA_KEY" || ! -s "$CA_CERT" ]]; then
        openssl genrsa -out "$CA_KEY" 2048 2>/dev/null
        openssl req -x509 -new -nodes -key "$CA_KEY" -sha256 -days 825 \
          -subj "/CN=consul-ca" -out "$CA_CERT" 2>/dev/null
      fi
      [[ -s "$SRV_KEY" ]] || openssl genrsa -out "$SRV_KEY" 2048 2>/dev/null
      csr="$(mktemp /tmp/qa-consul-csr.XXXXXX)"
      openssl req -new -key "$SRV_KEY" -subj "/CN=consul" -out "$csr" 2>/dev/null
      openssl x509 -req -in "$csr" -CA "$CA_CERT" -CAkey "$CA_KEY" -CAcreateserial \
        -out "$SRV_CERT" -days 825 -sha256 -extfile "$SAN_CONF" 2>/dev/null
      rm -f "$csr" "$SAN_CONF"
      chmod 400 "$CA_KEY" "$CA_CERT" "$SRV_KEY" "$SRV_CERT"
    fi
  fi
fi
if [[ $DRY_RUN -eq 0 ]]; then
  qa_log ok "secretos: $((${#QA_REQUIRED_SECRETS[@]} + 1)) verificados"
fi

# --- 5. Certificados ----------------------------------------------------------

if [[ ! -f "$CERT_DIR/api.localhost.pem" || ! -f "$CERT_DIR/s3.localhost.pem" ]]; then
  qa_log warn "faltan certificados locales; invocando gen-certs.sh"
  if ! run bash "$INFRA_DIR/scripts/gen-certs.sh"; then
    qa_die 3 "gen-certs.sh falló" "instala mkcert o openssl y reintenta"
  fi
fi

# --- 6. Compose config --------------------------------------------------------

if [[ $DRY_RUN -eq 1 ]]; then
  qa_log info "[dry-run] qa_compose config -q"
elif ! qa_compose config -q; then
  qa_die 3 "config de compose inválido para el proyecto $QA_PROJECT" \
    "revisa $ENV_FILE y los secretos; luego 'docker compose ... config' para el detalle"
else
  qa_log ok "compose config válido"
fi

# --- 7. Levantar --------------------------------------------------------------

COMPOSE_UP=()
for p in "${PROFILES[@]}"; do
  COMPOSE_UP+=(--profile "$p")
done
[[ $BUILD -eq 1 ]] && COMPOSE_UP+=(--build)
COMPOSE_UP+=(up -d)

qa_log info "levantando perfil(es): ${PROFILES[*]}"
if [[ $DRY_RUN -eq 1 ]]; then
  qa_log info "[dry-run] qa_compose ${COMPOSE_UP[*]}"
else
  qa_compose "${COMPOSE_UP[@]}"
fi

# --- 8. Gates de salud --------------------------------------------------------

START_EPOCH="$SECONDS"
DEADLINE=$((SECONDS + TIMEOUT))

run_gate "mongo (rs0 primario)" 60 mongo _probe_mongo_primary
run_gate --retry "mongo-init (exit 0)" 60 mongo-init _probe_exit0 mongo-init
run_gate "redis-streams (PING)" 30 redis-streams _probe_health redis-streams
run_gate "redis-ratelimit (PING)" 30 redis-ratelimit _probe_health redis-ratelimit
run_gate "minio (live)" 60 minio _probe_health minio
run_gate --retry "minio-init (buckets)" 60 minio-init _probe_exit0 minio-init

# Gates de sentinel (solo si el perfil sentinel está activo).
if has_profile sentinel; then
  run_gate "sentinel-1 (healthy)" 30 sentinel-1 _probe_health sentinel-1
  run_gate "sentinel-2 (healthy)" 30 sentinel-2 _probe_health sentinel-2
  run_gate "sentinel-3 (healthy)" 30 sentinel-3 _probe_health sentinel-3
  run_gate "redis-streams-replica-1 (healthy)" 30 redis-streams-replica-1 _probe_health redis-streams-replica-1
  run_gate "redis-streams-replica-2 (healthy)" 30 redis-streams-replica-2 _probe_health redis-streams-replica-2
  run_gate "sentinel master (myprimary)" 30 sentinel-1 _probe_sentinel_master
fi

if has_profile full; then
  run_gate --retry "minio-notify-init (webhook)" 60 minio-notify-init _probe_exit0 minio-notify-init
  run_gate "doc-service (readyz)" 90 doc-service _probe_wget doc-service 8080 /readyz
  run_gate "extraction-worker (readyz)" 90 extraction-worker _probe_curl extraction-worker 8081 /readyz
  run_gate "ocr-worker (healthz)" 90 ocr-worker _probe_curl ocr-worker 8080 /healthz
  run_gate "ratelimitd (healthz)" 30 ratelimitd _probe_wget ratelimitd 8090 /healthz
  run_gate "slo-exporter (metrics)" 30 slo-exporter _probe_wget slo-exporter 9100 /metrics
  run_gate "traefik (api.localhost)" 60 traefik _probe_http "https://api.localhost:$HTTPS_PORT/" '^(2|3|4)[0-9][0-9]$'
  run_gate "prometheus (ready)" 60 prometheus _probe_health prometheus
  run_gate "alertmanager (healthy)" 60 alertmanager _probe_health alertmanager
  run_gate "loki (ready)" 60 loki _probe_health loki
  run_gate "grafana (healthy)" 60 grafana _probe_health grafana
fi
if has_profile discovery || has_profile full; then
  run_gate "consul (leader)" 90 consul _probe_health consul
fi

# --- 9. Post-checks de contrato ----------------------------------------------

run_postcheck() {
  local name="$1" timeout="$2"
  shift 2
  local start=$SECONDS
  if [[ $NO_WAIT -eq 1 || $DRY_RUN -eq 1 ]]; then
    record_gate "$name" skip 0 "sin espera"
    return 0
  fi
  if qa_wait_for "$name" "$(effective_timeout "$timeout")" "$@"; then
    record_gate "$name" pass $((SECONDS - start)) ""
    qa_log ok "$name"
  else
    record_gate "$name" fail $((SECONDS - start)) "post-check"
    dump_failure ""
  fi
}

_probe_doc_404() {
  local code
  code="$(qa_http_code "https://api.localhost:$HTTPS_PORT/api/v2/documents/qa-nonexistent-$QA_RUN_ID")"
  [[ "$code" == "404" ]]
}
_probe_s3_head() {
  local code
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -I \
    "https://s3.localhost:$HTTPS_PORT/minio/health/live" 2>/dev/null || printf '000')"
  [[ "$code" == "200" ]]
}
_probe_legacy() {
  local code
  code="$(qa_http_code "https://api.localhost:$HTTPS_PORT/")"
  [[ "$code" != "000" ]]
}
_probe_stream_xlen() { _probe_stream; }

if has_profile full; then
  run_postcheck "doc-service responde 404 (no 502)" 30 _probe_doc_404
  run_postcheck "s3.localhost responde 200" 30 _probe_s3_head
  run_postcheck "stream y consumer group existen" 30 _probe_stream_xlen
  run_postcheck "ruta legacy responde" 30 _probe_legacy
fi

# --- 10. Resumen --------------------------------------------------------------

if [[ $DRY_RUN -eq 0 ]]; then
  write_up_json
fi

passed=0
for status in "${GATE_STATUSES[@]}"; do
  [[ "$status" == "pass" ]] && passed=$((passed + 1))
done

qa_log info "urls:"
qa_log info "  api        https://api.localhost:$HTTPS_PORT"
qa_log info "  s3         https://s3.localhost:$HTTPS_PORT"
if has_profile full; then
  qa_log info "  grafana    http://localhost:3000"
  qa_log info "  prometheus http://localhost:9090"
fi
if has_profile discovery || has_profile full; then
  qa_log info "  consul     https://consul.localhost:$HTTPS_PORT/ui"
fi
qa_log info "  artefactos $QA_RUN_DIR"
if [[ $DRY_RUN -eq 1 ]]; then
  qa_log info "dry-run: se definirían ${#GATE_NAMES[@]} gates de salud (no se ejecutaron)"
else
  qa_log ok "$passed/${#GATE_NAMES[@]} gates verdes en $((SECONDS - START_EPOCH))s (run $QA_RUN_ID)"
fi
qa_log info "siguiente: qa.sh status   |   qa.sh test doc-service --all   |   qa.sh e2e smoke"
