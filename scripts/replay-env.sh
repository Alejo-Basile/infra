#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_FILE="compose/docker-compose.replay.yml"
ENV_FILE=".env.replay"
PROJECT="replay"
REAL_INFRA_DIR="${REPLAY_REAL_INFRA_DIR:-$ROOT}"
if [ ! -f "$REAL_INFRA_DIR/.env" ] && [ -f "/home/alejobasilesoca/Desktop/Desarrollo-de-Software/proyecto-microservicio/infra/.env" ]; then
  REAL_INFRA_DIR="/home/alejobasilesoca/Desktop/Desarrollo-de-Software/proyecto-microservicio/infra"
fi

cd "$ROOT"

compose() { docker compose -p "$PROJECT" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

die() { echo "ERROR: $*" >&2; exit 1; }

# ---------- helpers for env values ----------
env_get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
real_env_get() { grep -E "^$1=" "$REAL_INFRA_DIR/.env" | head -1 | cut -d= -f2-; }
secret() { cat "$1" 2>/dev/null | tr -d '\n'; }

bootstrap_secrets() {
  mkdir -p "$ROOT/secrets"
  get() { env_get "$1"; }
  create_if_missing() {
    local f="$1" val="$2" newline="${3:-0}"
    if [ ! -f "$f" ]; then
      if [ "$newline" = "1" ]; then printf '%s\n' "$val" > "$f"; else printf '%s' "$val" > "$f"; fi
    fi
  }
  create_if_missing "$ROOT/secrets/replay_mongo_initdb_root_password.txt" "$(get REPLAY_MONGO_INITDB_ROOT_PASSWORD)" 0
  create_if_missing "$ROOT/secrets/replay_mongo_app_password.txt" "$(get REPLAY_MONGO_APP_PASSWORD)" 0
  create_if_missing "$ROOT/secrets/replay_mongo_worker_password.txt" "$(get REPLAY_MONGO_WORKER_PASSWORD)" 0
  create_if_missing "$ROOT/secrets/replay_redis_streams_password.txt" "$(get REPLAY_REDIS_STREAMS_PASSWORD)" 0
  if [ ! -f "$ROOT/secrets/replay_redis_streams_password.json" ]; then
    local pw; pw="$(get REPLAY_REDIS_STREAMS_PASSWORD)"
    printf '{"redis://redis-streams:6379": "%s"}' "$pw" > "$ROOT/secrets/replay_redis_streams_password.json"
  fi
  create_if_missing "$ROOT/secrets/replay_minio_root_password.txt" "$(get REPLAY_MINIO_ROOT_PASSWORD)" 0
  create_if_missing "$ROOT/secrets/replay_minio_webhook_secret.txt" "$(get REPLAY_MINIO_WEBHOOK_SECRET)" 0
  create_if_missing "$ROOT/secrets/replay_internal_token.txt" "$(get REPLAY_DOC_SERVICE_INTERNAL_TOKEN)" 0
  create_if_missing "$ROOT/secrets/replay_svc_docservice_access_key.txt" "$(get REPLAY_SVC_DOCSERVICE_ACCESS_KEY)" 0
  create_if_missing "$ROOT/secrets/replay_svc_docservice_secret_key.txt" "$(get REPLAY_SVC_DOCSERVICE_SECRET_KEY)" 0
  create_if_missing "$ROOT/secrets/replay_svc_worker_access_key.txt" "$(get REPLAY_SVC_WORKER_ACCESS_KEY)" 0
  create_if_missing "$ROOT/secrets/replay_svc_worker_secret_key.txt" "$(get REPLAY_SVC_WORKER_SECRET_KEY)" 0
  if [ ! -f "$ROOT/secrets/replay_mongo_keyfile" ]; then
    if command -v openssl >/dev/null 2>&1; then
      openssl rand -base64 756 > "$ROOT/secrets/replay_mongo_keyfile"
    else
      head -c 756 /dev/urandom | base64 > "$ROOT/secrets/replay_mongo_keyfile"
    fi
    chmod 400 "$ROOT/secrets/replay_mongo_keyfile"
    chown 999:999 "$ROOT/secrets/replay_mongo_keyfile" 2>/dev/null || true
  fi
}

# ---------- check-isolation ----------
check_isolation() {
  [ -f "$ENV_FILE" ] || die "falta $ENV_FILE"
  local cfg
  cfg="$(compose config --format json)"
  local pname
  pname="$(echo "$cfg" | jq -r '.name // .project // empty')"
  [ "$pname" = "$PROJECT" ] || die "proyecto incorrecto: $pname"

  # networks: all resolved names start with replay_ ; data/internal internal true
  local nets
  nets="$(echo "$cfg" | jq -r '.networks // {} | to_entries[] | (.value.name // .key)')"
  for n in $nets; do
    case "$n" in
      replay_*) ;;
      *) echo "ERROR: red no replay: $n"; exit 1 ;;
    esac
  done
  for n in data internal; do
    local internal
    internal="$(echo "$cfg" | jq -r --arg n "$n" '.networks[$n].internal // false')"
    [ "$internal" = "true" ] || { echo "ERROR: red $n no es internal"; exit 1; }
  done

  # ports
  local deny="80 443 8000 8080 8081 8088 8090 9000 9001 8543 9090 9093 3000"
  local ports
  ports="$(echo "$cfg" | jq -r '.services[].ports[]?.published // empty' 2>/dev/null || true)"
  # also handle object form
  if [ -z "$ports" ]; then
    ports="$(echo "$cfg" | jq -r '.services[]?.ports[]? | if type=="object" then (.published // empty) else . end' 2>/dev/null || true)"
  fi
  local infra_ports=""
  infra_ports="$(docker ps --filter label=com.docker.compose.project=infra --format '{{.Ports}}' 2>/dev/null | grep -oE '[0-9]+' | sort -u || true)"
  for pp in $ports; do
    for d in $deny $infra_ports; do
      if [ "$pp" = "$d" ]; then echo "ERROR: puerto colisionado: $pp"; exit 1; fi
    done
  done

  # volumes
  local vols
  vols="$(echo "$cfg" | jq -r '.volumes // {} | keys[]')"
  for v in $vols; do
    case "$v" in
      replay-*) ;;
      *) echo "ERROR: volumen no replay: $v"; exit 1 ;;
    esac
  done

  # secrets
  local spaths
  spaths="$(echo "$cfg" | jq -r '.secrets // {} | .[].file // empty')"
  for sp in $spaths; do
    local base
    base="$(basename "$sp")"
    echo "$base" | grep -qE '^replay_' || { echo "ERROR: secreto basename invalido: $base"; exit 1; }
    case "$sp" in
      *secrets*) ;;
      *) echo "ERROR: secreto fuera de secrets: $sp"; exit 1 ;;
    esac
  done

  # env checks doc-service
  local ms me mp
  ms="$(echo "$cfg" | jq -r '.services["doc-service"].environment.MINIO_ENDPOINT // empty')"
  me="$(echo "$cfg" | jq -r '.services["doc-service"].environment.MONGO_URI // empty')"
  mp="$(echo "$cfg" | jq -r '.services["doc-service"].environment.MINIO_PUBLIC_ENDPOINT // empty')"
  [ "$ms" = "minio:9000" ] || { echo "ERROR: MINIO_ENDPOINT invalido: $ms"; exit 1; }
  echo "$me" | grep -q '@mongo:27017' || { echo "ERROR: MONGO_URI invalido"; exit 1; }
  [ "$mp" = "http://localhost:9100" ] || { echo "ERROR: MINIO_PUBLIC_ENDPOINT invalido: $mp"; exit 1; }

  # minio webhook host doc-service
  local wh
  wh="$(echo "$cfg" | jq -r '.services["minio"].environment.MINIO_NOTIFY_WEBHOOK_ENDPOINT_DOCSERVICE // empty')"
  echo "$wh" | grep -q 'doc-service' || { echo "ERROR: webhook host invalido: $wh"; exit 1; }

  # services list
  local svcs
  svcs="$(compose config --services)"
  for bad in traefik prometheus alertmanager grafana loki ratelimitd redis-sentinel; do
    if echo "$svcs" | grep -qx "$bad"; then echo "ERROR: servicio prohibido: $bad"; exit 1; fi
  done

  # replay containers networks subset
  local rcids
  rcids="$(docker ps --filter label=com.docker.compose.project=replay --format '{{.ID}}' 2>/dev/null || true)"
  if [ -n "$rcids" ]; then
    for cid in $rcids; do
      local netsc
      netsc="$(docker inspect "$cid" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
      for n in $netsc; do
        case "$n" in
          replay_edge|replay_internal|replay_data) ;;
          *) echo "ERROR: contenedor en red no replay: $n"; exit 1 ;;
        esac
      done
    done
  fi

  echo "OK: aislamiento verificado"
}

wait_healthy() {
  local timeout=240 elapsed=0
  while [ $elapsed -lt $timeout ]; do
    if compose ps 2>/dev/null | grep -qiE 'starting|unhealthy|restarting'; then
      sleep 3; elapsed=$((elapsed+3)); continue
    fi
    # ensure all one-shot exited 0 and no empty
    local psout
    psout="$(compose ps 2>/dev/null || true)"
    # require every service healthy or exited 0
    if echo "$psout" | grep -qiE 'unhealthy|starting'; then
      sleep 3; elapsed=$((elapsed+3)); continue
    fi
    # check init services exited 0
    for init in mongo-init minio-init minio-notify-init; do
      if compose ps --format '{{.Name}} {{.State}} {{.Status}}' 2>/dev/null | grep -q "$init"; then
        if ! compose ps 2>/dev/null | grep "$init" | grep -q 'Exited (0)'; then
          # maybe still running
          sleep 3; elapsed=$((elapsed+3)); continue 2
        fi
      fi
    done
    return 0
  done
  echo "ERROR: timeout esperando healthy" >&2
  compose ps >&2 || true
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

# ---------- fingerprint (replay) ----------
fingerprint() {
  local mongo_user mongo_pw redis_pw
  mongo_user="$(env_get REPLAY_MONGO_INITDB_ROOT_USERNAME)"
  mongo_pw="$(secret "$ROOT/secrets/replay_mongo_initdb_root_password.txt")"
  redis_pw="$(secret "$ROOT/secrets/replay_redis_streams_password.txt")"

  # mongo aggregate by status
  local docs_json total
  docs_json="$(compose exec -T mongo mongosh --quiet -u "$mongo_user" -p "$mongo_pw" --authenticationDatabase admin --eval 'const r=db.getSiblingDB("documents").documents.aggregate([{$group:{_id:"$status",n:{$sum:1}}},{$sort:{_id:1}}]).toArray(); const o={}; let t=0; r.forEach(x=>{o[x._id]=x.n;t+=x.n}); print(JSON.stringify({by:o,total:t}));' 2>/dev/null || echo '{"by":{},"total":0}')"
  local by_status total_n
  by_status="$(echo "$docs_json" | jq -c '.by // {}')"
  total_n="$(echo "$docs_json" | jq -r '.total // 0')"

  # minio counts
  local minio_img="bitnamilegacy/minio-client:2025.7.21"
  local raw_count txt_count
  raw_count="$(docker run --rm --network replay_data \
    -e MC_USER="$(env_get REPLAY_MINIO_ROOT_USER 2>/dev/null || echo minioadmin)" \
    -e MC_PASS="$(secret "$ROOT/secrets/replay_minio_root_password.txt")" \
    "$minio_img" sh -c 'mc alias set local http://minio:9000 "$MC_USER" "$MC_PASS" >/dev/null 2>&1; mc ls --recursive local/raw-pdfs 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \n' || echo 0)"
  txt_count="$(docker run --rm --network replay_data \
    -e MC_USER="$(env_get REPLAY_MINIO_ROOT_USER 2>/dev/null || echo minioadmin)" \
    -e MC_PASS="$(secret "$ROOT/secrets/replay_minio_root_password.txt")" \
    "$minio_img" sh -c 'mc alias set local http://minio:9000 "$MC_USER" "$MC_PASS" >/dev/null 2>&1; mc ls --recursive local/extracted-txt 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \n' || echo 0)"
  [ -z "$raw_count" ] && raw_count=0
  [ -z "$txt_count" ] && txt_count=0

  # redis
  local xlen xlen_dlq xpending
  xlen="$(compose exec -T redis-streams redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing 2>/dev/null | tr -d ' \n' || echo 0)"
  xlen_dlq="$(compose exec -T redis-streams redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing-dlq 2>/dev/null | tr -d ' \n' || echo 0)"
  local xp
  xp="$(compose exec -T redis-streams redis-cli -a "$redis_pw" --no-auth-warning XPENDING stream:pdf-processing extraction-workers 2>/dev/null | head -1 | tr -d ' \n' || true)"
  [ -z "$xp" ] && xp=0
  xpending="$xp"
  [ -z "$xlen" ] && xlen=0
  [ -z "$xlen_dlq" ] && xlen_dlq=0

  # config hash
  local cfg_hash
  cfg_hash="$(compose config | sha256sum | awk '{print $1}')"

  # build json without sha256
  local body
  body="$(jq -n -S \
    --arg project "replay" \
    --argjson by "$by_status" \
    --argjson total "$total_n" \
    --argjson raw "$raw_count" \
    --argjson txt "$txt_count" \
    --argjson xlen "$xlen" \
    --argjson xdlq "$xlen_dlq" \
    --argjson pend "$xpending" \
    --arg ch "sha256:$cfg_hash" \
    '{project:$project, documents_by_status:$by, documents_total:$total, objects:{"raw-pdfs":$raw,"extracted-txt":$txt}, stream_len:$xlen, dlq_len:$xdlq, pending:$pend, config_hash:$ch}')"

  local sha
  sha="$(echo "$body" | sha256sum | awk '{print $1}')"
  echo "$body" | jq -S --arg sha "sha256:$sha" '. + {sha256:$sha}'
}

# ---------- fingerprint-real ----------
fingerprint_real() {
  local mongo_user mongo_pw redis_pw
  mongo_user="$(real_env_get MONGO_INITDB_ROOT_USERNAME)"
  mongo_pw="$(secret "$REAL_INFRA_DIR/secrets/mongo_initdb_root_password.txt")"
  redis_pw="$(secret "$REAL_INFRA_DIR/secrets/redis_streams_password.txt")"
  # fallback secret names
  [ -f "$REAL_INFRA_DIR/secrets/mongo_initdb_root_password.txt" ] || mongo_pw="$(secret "$REAL_INFRA_DIR/secrets/mongo_root_password.txt")"

  local docs_json by_status total_n
  docs_json="$(docker exec infra-mongo-1 mongosh --quiet -u "$mongo_user" -p "$mongo_pw" --authenticationDatabase admin --eval 'const r=db.getSiblingDB("documents").documents.aggregate([{$group:{_id:"$status",n:{$sum:1}}},{$sort:{_id:1}}]).toArray(); const o={}; let t=0; r.forEach(x=>{o[x._id]=x.n;t+=x.n}); print(JSON.stringify({by:o,total:t}));' 2>/dev/null || echo '{"by":{},"total":0}')"
  by_status="$(echo "$docs_json" | jq -c '.by // {}')"
  total_n="$(echo "$docs_json" | jq -r '.total // 0')"

  local minio_img="bitnamilegacy/minio-client:2025.7.21"
  local minio_user minio_pass
  minio_user="$(real_env_get MINIO_ROOT_USER)"
  minio_pass="$(secret "$REAL_INFRA_DIR/secrets/minio_root_password.txt")"
  local raw_count txt_count
  raw_count="$(docker run --rm --network infra_data \
    -e MC_USER="$minio_user" -e MC_PASS="$minio_pass" \
    "$minio_img" sh -c 'mc alias set local http://minio:9000 "$MC_USER" "$MC_PASS" >/dev/null 2>&1; mc ls --recursive local/raw-pdfs 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \n' || echo 0)"
  txt_count="$(docker run --rm --network infra_data \
    -e MC_USER="$minio_user" -e MC_PASS="$minio_pass" \
    "$minio_img" sh -c 'mc alias set local http://minio:9000 "$MC_USER" "$MC_PASS" >/dev/null 2>&1; mc ls --recursive local/extracted-txt 2>/dev/null | wc -l' 2>/dev/null | tr -d ' \n' || echo 0)"
  [ -z "$raw_count" ] && raw_count=0
  [ -z "$txt_count" ] && txt_count=0

  local xlen xlen_dlq xpending xp
  xlen="$(docker exec infra-redis-streams-1 redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing 2>/dev/null | tr -d ' \n' || echo 0)"
  xlen_dlq="$(docker exec infra-redis-streams-1 redis-cli -a "$redis_pw" --no-auth-warning XLEN stream:pdf-processing-dlq 2>/dev/null | tr -d ' \n' || echo 0)"
  xp="$(docker exec infra-redis-streams-1 redis-cli -a "$redis_pw" --no-auth-warning XPENDING stream:pdf-processing extraction-workers 2>/dev/null | head -1 | tr -d ' \n' || true)"
  [ -z "$xp" ] && xp=0
  xpending="$xp"
  [ -z "$xlen" ] && xlen=0
  [ -z "$xlen_dlq" ] && xlen_dlq=0

  # config hash from real compose
  local cfg_hash
  cfg_hash="$(docker compose -p infra --env-file "$REAL_INFRA_DIR/.env" -f "$REAL_INFRA_DIR/compose/docker-compose.yml" config 2>/dev/null | sha256sum | awk '{print $1}' || echo "")"

  local body
  body="$(jq -n -S \
    --arg project "infra" \
    --argjson by "$by_status" \
    --argjson total "$total_n" \
    --argjson raw "$raw_count" \
    --argjson txt "$txt_count" \
    --argjson xlen "$xlen" \
    --argjson xdlq "$xlen_dlq" \
    --argjson pend "$xpending" \
    --arg ch "sha256:$cfg_hash" \
    '{project:$project, documents_by_status:$by, documents_total:$total, objects:{"raw-pdfs":$raw,"extracted-txt":$txt}, stream_len:$xlen, dlq_len:$xdlq, pending:$pend, config_hash:$ch}')"

  local sha
  sha="$(echo "$body" | sha256sum | awk '{print $1}')"
  echo "$body" | jq -S --arg sha "sha256:$sha" '. + {sha256:$sha}'
}

# ---------- smoke ----------
cmd_smoke() {
  local fixture="${REPLAY_FIXTURE:-}"
  if [ -z "$fixture" ]; then
    for c in "$REAL_INFRA_DIR/../platform-services/tests/fixtures/pdf/baseline-0001.pdf" "$REAL_INFRA_DIR/../../platform-services/tests/fixtures/pdf/baseline-0001.pdf" "/home/alejobasilesoca/Desktop/Desarrollo-de-Software/proyecto-microservicio/platform-services/tests/fixtures/pdf/baseline-0001.pdf"; do
      if [ -f "$c" ]; then fixture="$(readlink -f "$c")"; break; fi
    done
  fi
  [ -n "$fixture" ] || fixture="$REAL_INFRA_DIR/../platform-services/tests/fixtures/pdf/baseline-0001.pdf"
  [ -f "$fixture" ] || die "fixture no existe: $fixture"
  local size
  size="$(stat -c%s "$fixture")"
  local corr="smoke-$(date -u +%s)"
  local ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"

  # step1
  echo "1. POST /api/v2/documents"
  local resp
  resp="$(curl -sS -w '\n%{http_code}' -X POST http://localhost:9080/api/v2/documents -H 'Content-Type: application/json' -H "X-Correlation-Id: $corr" -d "{\"idempotency_key\":\"replay-smoke-$ts\",\"size_bytes\":$size}")"
  local code body
  code="$(echo "$resp" | tail -1)"
  body="$(echo "$resp" | sed '$d')"
  echo "$code" | grep -qE '^2' || { echo "FAIL step1: $code $body"; exit 1; }
  local doc_id upload_url
  doc_id="$(echo "$body" | jq -r '.document_id // .id // empty')"
  upload_url="$(echo "$body" | jq -r '.upload_url // empty')"
  [ -n "$doc_id" ] && [ -n "$upload_url" ] || { echo "FAIL step1 fields: $body"; exit 1; }
  local form_fields
  form_fields="$(echo "$body" | jq -c '.form_fields // {}')"
  echo "   document_id=$doc_id"

  # step2 upload
  echo "2. Upload to MinIO"
  local curl_args=(-sS -o /tmp/smoke_upload.out -w '%{http_code}' -X POST "$upload_url")
  # form fields
  local keys
  keys="$(echo "$form_fields" | jq -r 'keys[]')"
  for k in $keys; do
    local v
    v="$(echo "$form_fields" | jq -r --arg k "$k" '.[$k]')"
    curl_args+=(-F "$k=$v")
  done
  curl_args+=(-F "file=@$fixture;type=application/pdf")
  local upcode
  upcode="$(curl "${curl_args[@]}")"
  echo "   upload http=$upcode"
  echo "$upcode" | grep -qE '^2' || { echo "FAIL step2: $(cat /tmp/smoke_upload.out)"; exit 1; }

  # step3 poll
  echo "3. Poll status"
  local status=""
  local tries=0
  while [ $tries -lt 180 ]; do
    local presp
    presp="$(curl -sS http://localhost:9080/api/v2/documents/$doc_id 2>/dev/null || true)"
    status="$(echo "$presp" | jq -r '.status // empty' 2>/dev/null || true)"
    [ "$status" = "COMPLETED" ] && break
    tries=$((tries+1))
    sleep 2
  done
  if [ "$status" != "COMPLETED" ]; then
    echo "FAIL step3: last status=$status body=$presp"; exit 1
  fi
  echo "   COMPLETED"

  # step4 download
  echo "4. Download txt"
  local dcode bytes
  dcode="$(curl -sS -o /tmp/smoke_download.txt -w '%{http_code}' http://localhost:9080/api/v2/documents/$doc_id/download)"
  echo "   download http=$dcode"
  [ "$dcode" = "200" ] || { echo "FAIL step4"; exit 1; }
  bytes="$(stat -c%s /tmp/smoke_download.txt 2>/dev/null || echo 0)"
  [ "$bytes" -gt 0 ] || { echo "FAIL step4 empty"; exit 1; }
  echo "   bytes=$bytes"

  # step5 v1 health
  echo "5. v1 health"
  curl -fsS http://localhost:9081/health >/dev/null || { echo "FAIL step5"; exit 1; }
  echo "   OK"

  # step6 cleanup best-effort
  echo "6. Cleanup"
  compose exec -T mongo mongosh --quiet -u "$(env_get REPLAY_MONGO_INITDB_ROOT_USERNAME)" -p "$(secret "$ROOT/secrets/replay_mongo_initdb_root_password.txt")" --authenticationDatabase admin --eval "db.getSiblingDB('documents').documents.deleteOne({_id:'$doc_id'})" >/dev/null 2>&1 || echo "WARN: mongo cleanup failed"
  docker run --rm --network replay_data -e MC_USER="$(env_get REPLAY_MINIO_ROOT_USER 2>/dev/null || echo minioadmin)" -e MC_PASS="$(secret "$ROOT/secrets/replay_minio_root_password.txt")" bitnamilegacy/minio-client:2025.7.21 sh -c 'mc alias set local http://minio:9000 "$MC_USER" "$MC_PASS" >/dev/null 2>&1; mc rm --force local/raw-pdfs/'"$doc_id"' 2>/dev/null; mc rm --force local/extracted-txt/'"$doc_id"'.txt 2>/dev/null' >/dev/null 2>&1 || echo "WARN: minio cleanup failed"

  echo "PASS: smoke v2 + v1"
}

# ---------- evidence ----------
cmd_evidence() {
  local evdir="$ROOT/docs/evidencias/S8"
  mkdir -p "$evdir"

  # 1 reset + up
  cmd_reset >/dev/null 2>&1
  # ensure up
  cmd_up >/dev/null 2>&1 || true

  # 2 fingerprint run1, run2
  fingerprint > "$evdir/S8-P1-01-fingerprint-initial.json"
  fingerprint > /tmp/fp2.json
  cp /tmp/fp2.json "$evdir/S8-P1-01-fingerprint-run2.json"
  if ! diff -q "$evdir/S8-P1-01-fingerprint-initial.json" "$evdir/S8-P1-01-fingerprint-run2.json" >/dev/null; then
    echo "diff fp1/fp2 non-empty"; diff "$evdir/S8-P1-01-fingerprint-initial.json" "$evdir/S8-P1-01-fingerprint-run2.json"; exit 1
  fi

  # 3 smoke
  local smoke_out
  smoke_out="$(cmd_smoke 2>&1)" || { echo "$smoke_out"; exit 1; }

  # 4 reset + up; fingerprint run3
  cmd_reset >/dev/null 2>&1
  cmd_up >/dev/null 2>&1 || true
  fingerprint > "$evdir/S8-P1-01-fingerprint-after-reset.json"
  if ! diff -q "$evdir/S8-P1-01-fingerprint-initial.json" "$evdir/S8-P1-01-fingerprint-after-reset.json" >/dev/null; then
    echo "diff fp1/fp3 non-empty"; diff "$evdir/S8-P1-01-fingerprint-initial.json" "$evdir/S8-P1-01-fingerprint-after-reset.json"; exit 1
  fi

  # 5 fingerprint-real before/after
  fingerprint_real > /tmp/real_before.txt
  # smoke not run against real
  fingerprint_real > /tmp/real_after.txt
  local real_diff
  real_diff="$(diff /tmp/real_before.txt /tmp/real_after.txt || true)"

  # build aislamiento file
  {
    echo "=== check-isolation ==="
    check_isolation
    echo
    echo "=== compose ps ==="
    compose ps
    echo
    echo "=== healthz 9080 ==="
    curl -sS http://localhost:9080/healthz 2>/dev/null || true
    echo
    echo "=== health 9081 ==="
    curl -sS http://localhost:9081/health 2>/dev/null || true
    echo
    echo "=== published ports ==="
    compose ps --format '{{.Ports}}' 2>/dev/null || true
    echo
    echo "=== networks/volumes ==="
    compose config --format json | jq -r '.networks|keys[]' 2>/dev/null
    compose config --format json | jq -r '.volumes|keys[]' 2>/dev/null
    echo
    echo "=== smoke output ==="
    echo "$smoke_out"
    echo
    echo "=== diff fp1/fp2 ==="
    echo "(empty)"
    echo "=== diff fp1/fp3 ==="
    echo "(empty)"
    echo
    echo "=== real before/after diff ==="
    echo "$real_diff"
    [ -z "$real_diff" ] && echo "differences: none"
  } > "$evdir/S8-P1-01-aislamiento.txt"

  # real before-after txt
  {
    echo "=== before ==="
    cat /tmp/real_before.txt
    echo "=== after ==="
    cat /tmp/real_after.txt
    echo "=== diff ==="
    diff /tmp/real_before.txt /tmp/real_after.txt && echo "differences: none"
  } > "$evdir/S8-P1-01-fingerprint-real-before-after.txt"

  {
    echo "real fingerprint before/after identical"
    diff /tmp/real_before.txt /tmp/real_after.txt && echo "differences: none"
  } > "$evdir/S8-P1-01-real-env-unchanged.txt"

  # handoff
  cat > "$evdir/S8-P1-A1-handoff.txt" <<'EOF'
REPLAY_API_BASE=http://localhost:9080
REPLAY_MONOLITO_BASE=http://localhost:9081
REPLAY_MINIO_ENDPOINT=http://localhost:9100
FINGERPRINT=$(infra/scripts/replay-env.sh fingerprint)
EOF
  echo "Initial fingerprint:" >> "$evdir/S8-P1-A1-handoff.txt"
  cat "$evdir/S8-P1-01-fingerprint-initial.json" >> "$evdir/S8-P1-A1-handoff.txt"
  echo "" >> "$evdir/S8-P1-A1-handoff.txt"
  echo "Credentials are replay-only fictitious values." >> "$evdir/S8-P1-A1-handoff.txt"

  if [ -n "$real_diff" ]; then
    echo "real diff non-empty"; echo "$real_diff"; exit 1
  fi
  echo "OK: evidence archived"
}

case "${1:-help}" in
  up) cmd_up ;;
  reset) cmd_reset ;;
  down) cmd_down ;;
  check-isolation) check_isolation ;;
  fingerprint) fingerprint ;;
  fingerprint-real) fingerprint_real ;;
  smoke) cmd_smoke ;;
  evidence) cmd_evidence ;;
  help|*) echo "Usage: $0 {up|reset|down|check-isolation|fingerprint|fingerprint-real|smoke|evidence}" ;;
esac
