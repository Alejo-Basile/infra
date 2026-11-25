#!/usr/bin/env bash
# status.sh — estado real del stack en modo lectura (plan §4.4).
# Nunca levanta, detiene ni recrea contenedores.
set -Eeuo pipefail

QA_SCRIPT_NAME="qa/status"
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h | --help) echo "Uso: qa.sh status [--json]"; exit 0 ;;
    *) qa_die 2 "opción desconocida: $1" "qa.sh status [--json]" ;;
  esac
done

qa_init

HTTPS_PORT="$(env_value TRAEFIK_HTTPS_PORT 443)"
STREAM_KEY="$(env_value REDIS_STREAM_KEY "stream:pdf-processing")"
DLQ_KEY="$(env_value REDIS_DLQ_KEY "stream:pdf-processing-dlq")"
export HTTPS_PORT

_services_json() {
  local raw
  raw="$(qa_compose ps --all --format json 2>/dev/null || true)"
  if [[ -z "$raw" ]]; then
    printf '[]'
  elif printf '%s' "$raw" | jq -e 'type == "array"' >/dev/null 2>&1; then
    printf '%s' "$raw"
  else
    printf '%s' "$raw" | jq -s '.'
  fi
}

_health_of() {
  local id
  id="$(qa_compose ps -q "$1" 2>/dev/null | head -1)"
  [[ -n "$id" ]] || {
    printf 'absent'
    return 0
  }
  docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || printf 'unknown'
}

_status_gate_of() {
  local value
  value="$(_health_of "$1")"
  case "$value" in
    healthy | running) printf 'pass' ;;
    *) printf 'fail' ;;
  esac
}

_mongo_primary() {
  local id
  id="$(qa_compose ps -q mongo 2>/dev/null | head -1)"
  [[ -n "$id" ]] || {
    printf 'absent'
    return 0
  }
  if docker exec "$id" sh -c \
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$(cat /run/secrets/mongo_initdb_root_password)" --authenticationDatabase admin --eval "db.hello().isWritablePrimary"' \
    2>/dev/null | grep -qx true; then
    printf 'primary'
  else
    printf 'not-primary'
  fi
}

_redis_len() {
  local id pw
  id="$(qa_compose ps -q redis-streams 2>/dev/null | head -1)"
  pw="$(cat "$SECRETS_DIR/redis_streams_password.txt" 2>/dev/null || true)"
  if [[ -z "$id" || -z "$pw" ]]; then
    printf 'n/a'
    return 0
  fi
  docker exec "$id" redis-cli -a "$pw" --no-auth-warning XLEN "$1" 2>/dev/null || printf 'n/a'
}

_sentinel_master() {
  local id out
  id="$(qa_compose ps -q sentinel-1 2>/dev/null | head -1)"
  [[ -n "$id" ]] || {
    printf 'n/a'
    return 0
  }
  out="$(docker exec "$id" redis-cli -p 26379 SENTINEL get-master-addr-by-name myprimary 2>/dev/null | head -2 | paste -sd: -)"
  [[ "$out" =~ ^[^:]+:[0-9]+$ ]] && printf '%s' "$out" || printf 'n/a'
}

GATES=()
_gate() { GATES+=("$1|$2|$3"); }

_gate "compose" "$([[ -f "$COMPOSE_FILE" ]] && echo pass || echo fail)" "$COMPOSE_FILE"
_gate "docker" "$(docker info >/dev/null 2>&1 && echo pass || echo fail)" "daemon"
mongo_primary="$(_mongo_primary)"
_gate "mongo" "$([[ "$mongo_primary" == "primary" ]] && echo pass || echo fail)" "health=$(_health_of mongo) rs=$mongo_primary"
_gate "redis-streams" "$(_status_gate_of redis-streams)" "health=$(_health_of redis-streams)"
_gate "redis-ratelimit" "$(_status_gate_of redis-ratelimit)" "health=$(_health_of redis-ratelimit)"
_gate "sentinel-1" "$(_status_gate_of sentinel-1)" "health=$(_health_of sentinel-1)"
_gate "sentinel-2" "$(_status_gate_of sentinel-2)" "health=$(_health_of sentinel-2)"
_gate "sentinel-3" "$(_status_gate_of sentinel-3)" "health=$(_health_of sentinel-3)"
sentinel_master="$(_sentinel_master)"
_gate "sentinel master" "$([[ "$sentinel_master" != "n/a" ]] && echo pass || echo fail)" "master=$sentinel_master"
_gate "redis-streams-replica-1" "$(_status_gate_of redis-streams-replica-1)" "health=$(_health_of redis-streams-replica-1)"
_gate "redis-streams-replica-2" "$(_status_gate_of redis-streams-replica-2)" "health=$(_health_of redis-streams-replica-2)"
_gate "minio" "$(_status_gate_of minio)" "health=$(_health_of minio)"
_gate "doc-service" "$(_status_gate_of doc-service)" "health=$(_health_of doc-service)"
_gate "extraction-worker" "$(_status_gate_of extraction-worker)" "health=$(_health_of extraction-worker)"
_gate "ocr-worker" "$(_status_gate_of ocr-worker)" "health=$(_health_of ocr-worker)"
_gate "ratelimitd" "$(_status_gate_of ratelimitd)" "health=$(_health_of ratelimitd)"
_gate "slo-exporter" "$(_status_gate_of slo-exporter)" "health=$(_health_of slo-exporter)"
_gate "traefik" "$(_status_gate_of traefik)" "health=$(_health_of traefik)"
_gate "consul" "$(_status_gate_of consul)" "health=$(_health_of consul)"

api_code="$(qa_http_code "https://api.localhost:$HTTPS_PORT/" 2>/dev/null || printf '000')"
s3_code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 -I "https://s3.localhost:$HTTPS_PORT/minio/health/live" 2>/dev/null || printf '000')"
_gate "api.localhost" "$([[ "$api_code" != "000" ]] && echo pass || echo fail)" "HTTP $api_code"
_gate "s3.localhost" "$([[ "$s3_code" == "200" ]] && echo pass || echo fail)" "HTTP $s3_code"

stream_len="$(_redis_len "$STREAM_KEY")"
dlq_len="$(_redis_len "$DLQ_KEY")"
_gate "stream:pdf-processing" "$([[ "$stream_len" != "n/a" ]] && echo pass || echo fail)" "XLEN=$stream_len"
_gate "stream:pdf-processing-dlq" "$([[ "$dlq_len" != "n/a" ]] && echo pass || echo fail)" "XLEN=$dlq_len"

if [[ $JSON -eq 1 ]]; then
  gates_json="[]"
  for entry in "${GATES[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    gates_json="$(printf '%s' "$gates_json" | jq \
      --arg name "$name" --arg status "$status" --arg detail "$detail" \
      '. + [{name:$name,status:$status,detail:$detail}]')"
  done
  jq -n \
    --arg run_id "$QA_RUN_ID" \
    --arg project "$QA_PROJECT" \
    --arg profile_hint "full+sentinel" \
    --arg generated_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson services "$(_services_json)" \
    --argjson gates "$gates_json" \
    '{run_id:$run_id,project:$project,profile_hint:$profile_hint,generated_at:$generated_at,services:$services,gates:$gates}'
else
  printf '%-22s %-10s %s\n' "GATE" "STATUS" "DETALLE"
  for entry in "${GATES[@]}"; do
    IFS='|' read -r name status detail <<<"$entry"
    printf '%-22s %-10s %s\n' "$name" "$status" "$detail"
  done
  printf '\nServicios (docker compose ps):\n'
  qa_compose ps --all 2>/dev/null || true
fi
exit 0
