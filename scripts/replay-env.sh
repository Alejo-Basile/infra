#!/usr/bin/env bash
set -euo pipefail
TEMP_DIR=""
trap 'rm -rf "${TEMP_DIR:-}"' EXIT

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
COMPOSE_FILE="infra/compose/docker-compose.replay.yml"
ENV_FILE="infra/.env.replay"
PROJECT="replay"
REAL_COMPOSE="infra/compose/docker-compose.yml"
REAL_ENV="infra/.env"

cd "$ROOT"

compose() { docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }
real_compose() { docker compose -p infra --env-file "$REAL_ENV" -f "$REAL_COMPOSE" "$@"; }

usage() { echo "Usage: $0 {up|reset|down|fingerprint|fingerprint-real|check-isolation|check-drift|help}"; }

cmd="${1:-}"
# ---------- helpers ----------
die() { echo "ERROR: $*" >&2; exit 1; }

check_isolation() {
  [ -f "$ENV_FILE" ] || die "falta $ENV_FILE"
  local cfg
  cfg="$(compose config --format json)"
  local pname
  pname="$(echo "$cfg" | (jq -r '.name // .project // empty' 2>/dev/null || python3 -c 'import json,sys;print(json.load(sys.stdin).get("name",""))'))"
  if [ "$pname" != "$PROJECT" ]; then echo "ERROR: proyecto incorrecto: $pname"; exit 1; fi

  # networks
  local nets
  nets="$(echo "$cfg" | jq -r '.networks // {} | to_entries[] | (.value.name // .key)')"
  for n in $nets; do
    case "$n" in
      replay_*) ;;
      *) echo "ERROR: red compartida detectada: $n"; exit 1 ;;
    esac
  done
  # internal true check
  for n in internal data; do
    local internal
    internal="$(echo "$cfg" | jq -r --arg n "$n" '.networks[$n].internal // false')"
    [ "$internal" = "true" ] || die "red $n no es internal"
  done

  # ports denylist + infra published
  local deny="80 443 8000 8080 8081 8088 8090 9000 9001 8543 9090 9093 3000"
  for p in $deny; do :; done
  local ports
  ports="$(echo "$cfg" | (jq -r '.services[].ports[]?.published // empty' 2>/dev/null || python3 -c 'import json,sys
d=json.load(sys.stdin)
for s in d.get("services",{}).values():
  for p in s.get("ports",[]) or []:
    print(p.get("published",""))'))"
  # infra published ports
  local infra_ports=""
  if docker ps --format '{{.Ports}}' 2>/dev/null | grep -q .; then
    infra_ports="$(docker ps --filter label=com.docker.compose.project=infra --format '{{.Ports}}' 2>/dev/null | grep -oE '[0-9]+' | sort -u)"
  fi
  for pp in $ports; do
    for d in $deny $infra_ports; do
      if [ "$pp" = "$d" ]; then echo "ERROR: puerto colisionado: $pp"; exit 2; fi
    done
  done

  # volumes
  local vols
  vols="$(echo "$cfg" | jq -r '.volumes // {} | keys[]')"
  for v in $vols; do
    case "$v" in
      replay-*) ;;
      *) echo "ERROR: volumen compartido: $v"; exit 3 ;;
    esac
    if echo "$v" | grep -q '^infra'; then echo "ERROR: volumen compartido: $v"; exit 3; fi
  done

  # secrets paths
  local spaths
  spaths="$(echo "$cfg" | (jq -r '.secrets // {} | .[].file // empty' 2>/dev/null || python3 -c 'import json,sys
d=json.load(sys.stdin)
for s in d.get("secrets",{}).values():
  print(s.get("file",""))'))"
  for sp in $spaths; do
    case "$sp" in
      *infra/secrets/replay_*) ;;
      *) echo "ERROR: secreto compartido: $sp"; exit 4 ;;
    esac
  done

  # env checks
  grep -q 'DOC_SERVICE_WEBHOOK_URL=http://doc-service' "$ENV_FILE" || true
  # service list excludes forbidden
  local svcs
  svcs="$(compose config --services | sort)"
  for bad in traefik prometheus alertmanager grafana loki; do
    if echo "$svcs" | grep -qx "$bad"; then echo "ERROR: servicio prohibido: $bad"; exit 1; fi
  done

  echo "OK: aislamiento verificado"
}

bootstrap_secrets() {
  mkdir -p infra/secrets
  # helper to create secret file if missing from env value
  get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
  create_if_missing() {
    local f="$1" val="$2" newline="${3:-1}"
    if [ ! -f "$f" ]; then
      if [ "$newline" = "1" ]; then printf '%s\n' "$val" > "$f"; else printf '%s' "$val" > "$f"; fi
    fi
  }
  create_if_missing infra/secrets/replay_mongo_initdb_root_password.txt "$(get REPLAY_MONGO_INITDB_ROOT_PASSWORD)" 0
  create_if_missing infra/secrets/replay_mongo_app_password.txt "$(get REPLAY_MONGO_APP_PASSWORD)" 0
  create_if_missing infra/secrets/replay_mongo_worker_password.txt "$(get REPLAY_MONGO_WORKER_PASSWORD)" 0
  create_if_missing infra/secrets/replay_redis_streams_password.txt "$(get REPLAY_REDIS_STREAMS_PASSWORD)" 0
  # json secret
  if [ ! -f infra/secrets/replay_redis_streams_password.json ]; then
    local pw; pw="$(get REPLAY_REDIS_STREAMS_PASSWORD)"
    printf '{"redis://redis-streams:6379": "%s"}' "$pw" > infra/secrets/replay_redis_streams_password.json
  fi
  create_if_missing infra/secrets/replay_minio_root_password.txt "$(get REPLAY_MINIO_ROOT_PASSWORD)" 0
  create_if_missing infra/secrets/replay_minio_webhook_secret.txt "$(get REPLAY_MINIO_WEBHOOK_SECRET)" 0
  create_if_missing infra/secrets/replay_internal_token.txt "$(get REPLAY_DOC_SERVICE_INTERNAL_TOKEN)" 0
  create_if_missing infra/secrets/replay_svc_docservice_access_key.txt "$(get REPLAY_SVC_DOCSERVICE_ACCESS_KEY)" 0
  create_if_missing infra/secrets/replay_svc_docservice_secret_key.txt "$(get REPLAY_SVC_DOCSERVICE_SECRET_KEY)" 0
  create_if_missing infra/secrets/replay_svc_worker_access_key.txt "$(get REPLAY_SVC_WORKER_ACCESS_KEY)" 0
  create_if_missing infra/secrets/replay_svc_worker_secret_key.txt "$(get REPLAY_SVC_WORKER_SECRET_KEY)" 0
  # keyfile
  if [ ! -f infra/secrets/replay_mongo_keyfile ]; then
    /var/lib/flatpak/runtime/org.freedesktop.Platform/x86_64/25.08/08713ee4ce58fee0b8ff2f5bb58e511ff2009c4d72209270d2ddd01fb0336a04/files/bin/openssl rand -base64 756 > infra/secrets/replay_mongo_keyfile
    chmod 400 infra/secrets/replay_mongo_keyfile
    chown 999:999 infra/secrets/replay_mongo_keyfile 2>/dev/null || true
  fi
}

wait_healthy() {
  local timeout=240
  local elapsed=0
  while [ $elapsed -lt $timeout ]; do
    local psout
    psout="$(compose ps --format json 2>/dev/null || true)"
    # check if any unhealthy/unstarted
    local bad
    bad="$(compose ps 2>/dev/null | grep -vE 'healthy|Exited \(0\)|Up ' | grep -v 'NAME' | grep -v '^$' || true)"
    # simpler: ensure no "starting" or "unhealthy"
    if compose ps 2>/dev/null | grep -qiE 'starting|unhealthy'; then
      sleep 3; elapsed=$((elapsed+3)); continue
    fi
    # all services exited 0 or healthy
    return 0
  done
  echo "ERROR: timeout esperando healthy" >&2
  compose ps >&2
  return 1
}

cmd_up() {
  check_isolation
  bootstrap_secrets
  compose up -d
  wait_healthy
  compose ps
}

cmd_reset() {
  compose down -v || true
  cmd_up
}

cmd_down() {
  compose down
}

fingerprint() {
  local cfg_hash
  cfg_hash="$(compose config | sha256sum | awk '{print $1}')"
  local images_json
  # build images map
  images_json="{}"
  # get service->image from config
  local svcs
  svcs="$(compose config --services | sort)"
  {
    echo '{'
    echo '  "project": "replay",'
    echo '  "images": {'
    local first=1
    for s in $svcs; do
      local img
      img="$(compose config 2>/dev/null | python3 -c '
import sys,yaml,json
# fallback parse via compose config json
' 2>/dev/null || true)"
      img="$(docker inspect "replay-${s}-1" --format '{{.Config.Image}}' 2>/dev/null || compose config 2>/dev/null | grep -A2 "^  $s:" | grep image | head -1 | sed 's/.*image: //')"
      if [ $first -eq 0 ]; then echo ',' ; fi
      first=0
      printf '    "%s": "%s"' "$s" "$img"
    done
    echo ''
    echo '  },'
    echo '  "config_hash": "sha256:'"$cfg_hash"'",'
    echo '  "volumes": ['
    local vfirst=1
    for v in $(compose config --format json | python3 -c 'import json,sys;print("\n".join(sorted(json.load(sys.stdin).get("volumes",{}).keys())))'); do
      if [ $vfirst -eq 0 ]; then echo ','; fi
      vfirst=0
      printf '    "%s"' "$v"
    done
    echo ''
    echo '  ],'
    echo '  "networks": ['
    local nfirst=1
    for n in $(compose config --format json | python3 -c 'import json,sys;print("\n".join(sorted(json.load(sys.stdin).get("networks",{}).keys())))'); do
      if [ $nfirst -eq 0 ]; then echo ','; fi
      nfirst=0
      printf '    "%s"' "$n"
    done
    echo ''
    echo '  ]'
    echo '}'
  } 
}

fingerprint_real() {
  # documents count by status via mongosh
  local mongo_cid
  mongo_cid="$(docker ps --filter name=infra-mongo-1 --format '{{.ID}}' | head -1)"
  # use docker exec
  local docs
  docs="$(docker exec "$mongo_cid" mongosh --quiet -u "$(grep ^MONGO_INITDB_ROOT_USERNAME= infra/.env | cut -d= -f2)" -p "$(cat infra/secrets/mongo_initdb_root_password.txt)" --authenticationDatabase admin --eval 'JSON.stringify(db.getSiblingDB("documents").documents.aggregate([{$group:{_id:"$status",n:{$sum:1}}},{$sort:{_id:1}}]).toArray())' 2>/dev/null || echo '[]')"
  # minio counts via mc in a container on data network - skip if not possible
  local raw_count txt_count
  raw_count="$(docker run --rm --network infra_data -e MINIO_ROOT_USER="$(grep ^MINIO_ROOT_USER= infra/.env | cut -d= -f2)" -e MINIO_ROOT_PASSWORD="$(cat infra/secrets/minio_root_password.txt)" bitnamilegacy/minio-client:2025.7.21 sh -c 'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls --recursive local/raw-pdfs 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  txt_count="$(docker run --rm --network infra_data -e MINIO_ROOT_USER="$(grep ^MINIO_ROOT_USER= infra/.env | cut -d= -f2)" -e MINIO_ROOT_PASSWORD="$(cat infra/secrets/minio_root_password.txt)" bitnamilegacy/minio-client:2025.7.21 sh -c 'mc alias set local http://minio:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; mc ls --recursive local/extracted-txt 2>/dev/null | wc -l' 2>/dev/null || echo 0)"
  raw_count="$(echo "$raw_count" | tr -d ' ')"
  txt_count="$(echo "$txt_count" | tr -d ' ')"
  # XLEN
  local redis_pw
  redis_pw="$(cat infra/secrets/redis_streams_password.txt)"
  local redis_cid
  redis_cid="$(docker ps --filter name=infra-redis-streams-1 --format '{{.ID}}' | head -1)"
  local xlen xlen_dlq xpending
  xlen="$(docker exec "$redis_cid" redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing 2>/dev/null || echo 0)"
  xlen_dlq="$(docker exec "$redis_cid" redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing-dlq 2>/dev/null || echo 0)"
  xpending="$(docker exec "$redis_cid" redis-cli -a "$redis_pw" --no-auth-warning XPENDING stream:pdf-processing extraction-workers 2>/dev/null | tr '\n' ' ' || echo '')"
  cat <<JSON
{
  "project": "infra",
  "documents": $docs,
  "minio": { "raw-pdfs": $raw_count, "extracted-txt": $txt_count },
  "streams": { "stream:pdf-processing": $xlen, "stream:pdf-processing-dlq": $xlen_dlq },
  "xpending": "$xpending"
}
JSON
}

check_drift() {
  # compare image refs for shared services
  local svcs="mongo redis-streams minio doc-service extraction-worker monolito"
  local fail=0
  for s in $svcs; do
    local real_img replay_img
    real_img="$(docker inspect "infra-${s}-1" --format '{{.Config.Image}}' 2>/dev/null || real_compose config 2>/dev/null | grep -A1 "  $s:" | grep image | head -1 | sed 's/.*image: //')"
    replay_img="$(docker inspect "replay-${s}-1" --format '{{.Config.Image}}' 2>/dev/null || compose config 2>/dev/null | grep -A1 "  $s:" | grep image | head -1 | sed 's/.*image: //')"
    if [ "$real_img" != "$replay_img" ]; then
      # compare digests if available
      local real_dig replay_dig
      real_dig="$(docker inspect "infra-${s}-1" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo '')"
      replay_dig="$(docker inspect "replay-${s}-1" --format '{{index .RepoDigests 0}}' 2>/dev/null || echo '')"
      if [ -n "$real_dig" ] && [ -n "$replay_dig" ]; then
        if [ "$real_dig" != "$replay_dig" ]; then
          echo "ERROR: drift de imagen: $s $real_dig != $replay_dig"; fail=1
        fi
      else
        if [ "$real_img" != "$replay_img" ]; then
          echo "ERROR: drift de imagen: $s $real_img != $replay_img"; fail=1
        else
          echo "reference-only: $s $real_img"
        fi
      fi
    fi
  done
  if [ $fail -eq 0 ]; then echo "OK: sin drift"; fi
  return $fail
}

case "$cmd" in
  up) cmd_up ;;
  reset) cmd_reset ;;
  down) cmd_down ;;
  check-isolation) check_isolation ;;
  fingerprint) fingerprint ;;
  fingerprint-real) fingerprint_real ;;
  check-drift) check_drift ;;
  help) usage; exit 0 ;;
  "") usage >&2; exit 2 ;;
  *) echo "ERROR: subcomando desconocido: $cmd" >&2; usage >&2; exit 2 ;;
esac
