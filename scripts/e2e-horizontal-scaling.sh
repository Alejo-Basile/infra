#!/usr/bin/env bash
# E2E — S4-P1-01: escalado horizontal sin estado del doc-service.
#
# Verifica contra el stack `full` local (imagen `doc-service:local`):
#   S1  dos replicas de doc-service, misma imagen (mismo Image ID), ambas healthy,
#       y un Redis Stream aislado por corrida (REDIS_STREAM_KEY unico).
#   S2  Traefik reparte GET /healthz entre las dos replicas: el access log debe
#       mostrar al menos dos ServiceAddr distintos y ambos deben ser las IPs
#       `infra_internal` de los dos contenedores.
#   S3  50 documentos creados por POST /api/v2/documents + subida prefirmada a
#       MinIO producen exactamente 50 mensajes (XLEN = 50) en el stream aislado.
#       Los 50 document_id son unicos y coinciden con los creados; cada entrada
#       tiene exactamente un campo `payload` con las 5 claves del contrato.
#   S4  Re-disparar UPLOADED de un documento ya encolado no agrega mensajes: la
#       clave dedup:<document_id> existe y su TTL esta en (0, 600] segundos.
#   S6  Las contrasenas se leen DENTRO de los contenedores desde /run/secrets/*;
#       nunca se imprimen ni se pasan por argv del host. El script falla con
#       exit != 0 si una asercion falla y siempre intenta el rollback.
#
# La clave de stream por defecto NO se usa para contar: mezcla entradas legacy
# de formato plano. El script genera una clave aislada salvo que se pase
# E2E_STREAM_KEY.
#
# Uso:
#   E2E_INSECURE=1 scripts/e2e-horizontal-scaling.sh
#
# Variables:
#   API_BASE_URL    default https://api.localhost:${TRAEFIK_HTTPS_PORT:-443}
#   E2E_INSECURE    default 1 (certificados mkcert no confiables en el host)
#   E2E_CA_CERT     CA de mkcert; tiene prioridad sobre -k
#   E2E_TIMEOUT     segundos para esperar salud/stream (default 120)
#   E2E_STREAM_KEY  clave de stream aislada (default: generada por corrida)
#
# No deja contenedores de prueba: al terminar escala doc-service al numero
# original de replicas y restaura el REDIS_STREAM_KEY por defecto de `.env`.
# El stream aislado se conserva para auditoria y se imprime su clave.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
BUILD_FILE="$INFRA_DIR/compose/docker-compose.build.yml"
ENV_FILE="$INFRA_DIR/.env"

fail=0
ok()    { echo "  [OK]   $*"; }
bad()   { echo "  [FAIL] $*"; fail=$((fail + 1)); }
info()  { echo; echo "== $* =="; }
note()  { echo "  [INFO] $*"; }

summary() {
  echo
  if [ "$fail" -eq 0 ]; then
    echo "E2E horizontal scaling OK — 2 replicas, 50 documentos, 50 mensajes, dedup verificado."
    exit 0
  fi
  echo "E2E horizontal scaling with $fail failure(s). Review the [FAIL] lines."
  exit 1
}

# --- Settings -----------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ENV_FILE"
  set +a
fi

TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-443}"
API_BASE_URL="${API_BASE_URL:-https://api.localhost:${TRAEFIK_HTTPS_PORT}}"
E2E_INSECURE="${E2E_INSECURE:-1}"
E2E_TIMEOUT="${E2E_TIMEOUT:-120}"
MONGO_DATABASE="${MONGO_DATABASE:-documents}"
# Clave por defecto de `.env`; se usa para el rollback sin importar lo que pase.
DEFAULT_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"
# Clave aislada por corrida: nunca se cuenta el stream por defecto (formato legacy).
STREAM_KEY="${E2E_STREAM_KEY:-stream:pdf-processing:s4p101-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 4)}"
DOC_COUNT=50

COMPOSE=(docker compose -f "$COMPOSE_FILE" -f "$BUILD_FILE" --env-file "$ENV_FILE" --profile full)

CURL_TLS=()
[ "$E2E_INSECURE" = "1" ] && CURL_TLS+=(-k)
[ -n "${E2E_CA_CERT:-}" ] && CURL_TLS+=(--cacert "$E2E_CA_CERT")
CURL_BASE=(curl -sS --max-time 20 "${CURL_TLS[@]}")

# --- Helpers ------------------------------------------------------------------
expect_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1 = $3"
  else
    bad "$1: expected '$2', got '$3'"
  fi
}

# Ejecuta un comando de redis-cli dentro del contenedor. El password se lee de
# /run/secrets dentro del contenedor: no aparece en argv del host.
redis_exec() { # <args... para redis-cli>
  "${COMPOSE[@]}" exec -T redis-streams sh -c \
    'redis-cli -a "$(cat /run/secrets/redis_streams_password)" --no-auth-warning --json "$@"' \
    _ "$@" 2>/dev/null
}

# Ejecuta un script JS en mongosh dentro del contenedor. El password root se lee
# de /run/secrets dentro del contenedor: no aparece en argv del host.
mongo_eval() { # <js>
  "${COMPOSE[@]}" exec -T mongo sh -c \
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$(cat /run/secrets/mongo_initdb_root_password)" --authenticationDatabase admin '"$MONGO_DATABASE"' --eval "$1"' \
    _ "$1" 2>/dev/null
}

wait_doc_healthy() { # <desired-count> <timeout-seconds>
  local desired="$1" timeout="$2" i=0 cid st
  local -a ids
  while [ "$i" -lt "$timeout" ]; do
    mapfile -t ids < <("${COMPOSE[@]}" ps -q doc-service 2>/dev/null)
    if [ "${#ids[@]}" -eq "$desired" ]; then
      local all_healthy=1
      for cid in "${ids[@]}"; do
        st="$(docker inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$cid" 2>/dev/null)"
        [ "$st" = "running/healthy" ] || all_healthy=0
      done
      [ "$all_healthy" -eq 1 ] && return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# El healthcheck HTTP no garantiza que el Change Stream ya este escuchando.
# Con un resume token viejo (stack de horas), el watcher descarta el token y
# abre un stream fresco: los eventos ocurridos antes de ese Watch se pierden.
# Esperar el log "change stream watcher iniciado" de cada replica garantiza que
# el stream esta abierto antes de subir documentos.
wait_watchers_ready() { # <timeout-seconds>; usa DOC_CIDS
  local timeout="$1" i=0 cid ready
  while [ "$i" -lt "$timeout" ]; do
    ready=1
    for cid in "${DOC_CIDS[@]}"; do
      docker logs "$cid" 2>&1 | grep -qF 'change stream watcher iniciado' || ready=0
    done
    [ "$ready" -eq 1 ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

truncate_list() { # <one entry per line>
  sed '/^[[:space:]]*$/d' <<<"$1"
}

# Estado de rollback protegido para que el trap no lo repita.
ROLLED_BACK=0

rollback() {
  [ "$ROLLED_BACK" -eq 1 ] && return 0
  ROLLED_BACK=1
  [ -n "${ORIGINAL_REPLICAS:-}" ] || { note "sin replicas originales registradas; rollback omitido"; return 0; }

  info "S5. Rollback: doc-service -> $ORIGINAL_REPLICAS replica(s), stream por defecto"
  if ! REDIS_STREAM_KEY="$DEFAULT_STREAM_KEY" "${COMPOSE[@]}" up -d --no-deps --force-recreate \
      --scale "doc-service=$ORIGINAL_REPLICAS" doc-service >/dev/null 2>&1; then
    bad "rollback: compose up failed"
    return 1
  fi
  if ! wait_doc_healthy "$ORIGINAL_REPLICAS" "$E2E_TIMEOUT"; then
    bad "rollback: doc-service did not reach $ORIGINAL_REPLICAS healthy replica(s)"
    return 1
  fi
  local -a ids
  mapfile -t ids < <("${COMPOSE[@]}" ps -q doc-service 2>/dev/null)
  if [ "${#ids[@]}" -eq "$ORIGINAL_REPLICAS" ]; then
    ok "doc-service restored to ${#ids[@]} replica(s)"
  else
    bad "rollback: expected $ORIGINAL_REPLICAS replica(s), found ${#ids[@]}"
  fi
  note "REDIS_STREAM_KEY restaurado a: $DEFAULT_STREAM_KEY"
  note "stream aislado conservado para auditoria: $STREAM_KEY"
}

finish() {
  local rc=$?
  if [ "$ROLLED_BACK" -eq 0 ]; then
    rollback || rc=1
  fi
  [ -n "${WORK_DIR:-}" ] && rm -rf "$WORK_DIR"
  exit "$rc"
}
trap finish EXIT

# --- Preflight ----------------------------------------------------------------
info "Preflight"
for t in curl jq openssl docker; do
  command -v "$t" >/dev/null 2>&1 && ok "tool: $t" || bad "missing tool: $t"
done
[ -r "$ENV_FILE" ] && ok "infra/.env readable" || bad "infra/.env is missing"
[ "$fail" -gt 0 ] && summary

if "${CURL_BASE[@]}" "$API_BASE_URL/healthz" >/dev/null 2>&1; then
  ok "stack reachable via Traefik: $API_BASE_URL/healthz"
else
  bad "cannot reach $API_BASE_URL/healthz (is the full stack up?)"
  summary
fi

ORIGINAL_REPLICAS="$("${COMPOSE[@]}" ps -q doc-service 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ORIGINAL_REPLICAS:-0}" -ge 1 ] 2>/dev/null; then
  ok "original doc-service replica count: $ORIGINAL_REPLICAS"
else
  bad "no running doc-service replica to start from"
  summary
fi

EXPECTED_IMAGE_ID="$(docker image inspect doc-service:local --format '{{.Id}}' 2>/dev/null)"
if [ -n "$EXPECTED_IMAGE_ID" ]; then
  ok "local image doc-service:local = ${EXPECTED_IMAGE_ID:0:19}..."
else
  bad "image doc-service:local not found"
  summary
fi

WORK_DIR="$(mktemp -d)"
PDF="$WORK_DIR/fixture.pdf"
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$PDF"
FILE_SIZE="$(wc -c < "$PDF" | tr -d ' ')"

note "clave de stream aislada: $STREAM_KEY"

# --- S1. Dos replicas con la misma imagen ------------------------------------
info "S1. Escalar doc-service a 2 replicas (REDIS_STREAM_KEY aislada)"
if ! REDIS_STREAM_KEY="$STREAM_KEY" "${COMPOSE[@]}" up -d --no-deps --force-recreate \
    --scale doc-service=2 doc-service; then
  bad "compose up for 2 replicas failed"
  summary
fi
if ! wait_doc_healthy 2 "$E2E_TIMEOUT"; then
  bad "doc-service did not reach 2 healthy replicas within ${E2E_TIMEOUT}s"
  summary
fi

DOC_CIDS=()
mapfile -t DOC_CIDS < <("${COMPOSE[@]}" ps -q doc-service 2>/dev/null)
expect_eq "running doc-service containers" "2" "${#DOC_CIDS[@]}"

DOC_IPS=()
for cid in "${DOC_CIDS[@]}"; do
  c_image="$(docker inspect -f '{{.Image}}' "$cid" 2>/dev/null)"
  c_ref="$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)"
  c_ip="$(docker inspect -f '{{with index .NetworkSettings.Networks "infra_internal"}}{{.IPAddress}}{{end}}' "$cid" 2>/dev/null)"
  expect_eq "replica ${cid:0:12} Image ID" "$EXPECTED_IMAGE_ID" "$c_image"
  expect_eq "replica ${cid:0:12} image ref" "doc-service:local" "$c_ref"
  if [ -n "$c_ip" ]; then
    DOC_IPS+=("$c_ip")
    ok "replica ${cid:0:12} infra_internal IP: $c_ip"
  else
    bad "replica ${cid:0:12} has no infra_internal IP"
  fi
done
if [ "$(printf '%s\n' "${DOC_IPS[@]:-}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')" -eq 2 ]; then
  ok "two distinct infra_internal IPs"
else
  bad "expected two distinct infra_internal IPs"
fi

if wait_watchers_ready "$E2E_TIMEOUT"; then
  ok "both replicas have an open Change Stream watcher"
else
  bad "Change Stream watcher not ready in both replicas within ${E2E_TIMEOUT}s"
  for cid in "${DOC_CIDS[@]}"; do
    echo "  [INFO] last log lines for ${cid:0:12}:"
    docker logs "$cid" 2>&1 | tail -5 | sed 's/^/         /'
  done
  summary
fi

# --- S2. Traefik reparte entre las dos replicas ------------------------------
info "S2. Traefik load balancing (ServiceAddr en access log)"
TRAEFIK_CID="$("${COMPOSE[@]}" ps -q traefik 2>/dev/null)"
if [ -n "$TRAEFIK_CID" ]; then
  ok "traefik container: ${TRAEFIK_CID:0:12}"
else
  bad "traefik container not found"
fi

PFX="s4p101-$(date -u +%Y%m%dT%H%M%SZ)-$(openssl rand -hex 3)"
SINCE="$(date -u -d '2 seconds ago' +%Y-%m-%dT%H:%M:%SZ)"
PROBE_FAIL=0
SEEN_ADDRS=""
attempt=0
while [ "$attempt" -lt 10 ]; do
  for i in $(seq 1 20); do
    pcode="$("${CURL_BASE[@]}" -H "X-Correlation-Id: ${PFX}-${attempt}-${i}" \
      -o /dev/null -w '%{http_code}' "$API_BASE_URL/healthz" 2>/dev/null)" || pcode="000"
    [ "$pcode" = "200" ] || PROBE_FAIL=$((PROBE_FAIL + 1))
  done
  sleep 1
  if [ -n "$TRAEFIK_CID" ]; then
    SEEN_ADDRS="$(docker logs "$TRAEFIK_CID" --since "$SINCE" 2>&1 \
      | jq -Rr --arg p "${PFX}-" \
          'fromjson? | select((.["request_X-Correlation-Id"] // "") | startswith($p)) | .ServiceAddr' 2>/dev/null \
      | sed '/^[[:space:]]*$/d' | sort -u)"
  fi
  [ "$(truncate_list "$SEEN_ADDRS" | wc -l | tr -d ' ')" -ge 2 ] && break
  attempt=$((attempt + 1))
done

[ "$PROBE_FAIL" -eq 0 ] && ok "all /healthz probes returned 200" \
  || bad "$PROBE_FAIL /healthz probe(s) did not return 200"

SEEN_COUNT="$(truncate_list "$SEEN_ADDRS" | wc -l | tr -d ' ')"
if [ "$SEEN_COUNT" -ge 2 ]; then
  ok "Traefik served requests from $SEEN_COUNT distinct ServiceAddr"
  echo "$SEEN_ADDRS" | sed 's/^/         /'
else
  bad "Traefik used $SEEN_COUNT distinct ServiceAddr (expected >= 2)"
fi

EXPECTED_ADDRS=()
for ip in "${DOC_IPS[@]}"; do
  EXPECTED_ADDRS+=("${ip}:8080")
  if grep -qxF "${ip}:8080" <<<"$SEEN_ADDRS"; then
    ok "ServiceAddr covers replica ${ip}:8080"
  else
    bad "ServiceAddr does not include replica ${ip}:8080"
  fi
done
# Cada direccion observada debe pertenecer a una de las dos replicas actuales.
while IFS= read -r addr; do
  [ -n "$addr" ] || continue
  found=0
  for exp in "${EXPECTED_ADDRS[@]}"; do
    [ "$addr" = "$exp" ] && found=1
  done
  [ "$found" -eq 1 ] || bad "unexpected ServiceAddr observed: $addr"
done <<<"$SEEN_ADDRS"

# --- S3. 50 documentos -> 50 mensajes ----------------------------------------
info "S3. Crear y subir 50 documentos unicos por el contrato publico"
CREATED_IDS=()
HDR_BODY="$WORK_DIR/create.json"
for n in $(seq 1 "$DOC_COUNT"); do
  doc_id="$(openssl rand -hex 16)"
  body_json="$(jq -n --arg ik "$doc_id" --argjson sz "$FILE_SIZE" \
    '{idempotency_key:$ik, size_bytes:$sz}')"
  code="$("${CURL_BASE[@]}" -X POST "$API_BASE_URL/api/v2/documents" \
    -H 'Content-Type: application/json' -d "$body_json" \
    -o "$HDR_BODY" -w '%{http_code}' 2>/dev/null)" || code="000"
  if [ "$code" != "201" ]; then
    bad "document $n: create returned HTTP $code"
    summary
  fi

  resp_id="$(jq -r '.document_id // ""' "$HDR_BODY" 2>/dev/null)"
  upload_url="$(jq -r '.upload_url // ""' "$HDR_BODY" 2>/dev/null)"
  if [ "$resp_id" != "$doc_id" ]; then
    bad "document $n: response document_id '$resp_id' != idempotency key"
    summary
  fi
  if [ -z "$upload_url" ]; then
    bad "document $n: upload_url missing"
    summary
  fi

  FORM_ARGS=()
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && FORM_ARGS+=(-F "$k=$v")
  done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' "$HDR_BODY")

  up_code="$("${CURL_BASE[@]}" -X POST "$upload_url" "${FORM_ARGS[@]}" \
    -F "file=@${PDF};type=application/pdf" -o /dev/null -w '%{http_code}' 2>/dev/null)" \
    || up_code="000"
  case "$up_code" in
    200|201|204) : ;;
    *)
      bad "document $n: presigned upload returned HTTP $up_code"
      summary
      ;;
  esac
  CREATED_IDS+=("$doc_id")
  [ $((n % 10)) -eq 0 ] && note "uploaded $n/$DOC_COUNT"
done
ok "$DOC_COUNT documents created and uploaded (${FILE_SIZE} bytes each)"

info "S3. Esperar XLEN == $DOC_COUNT en el stream aislado"
XLEN=-1
i=0
while [ "$i" -lt "$E2E_TIMEOUT" ]; do
  XLEN="$(redis_exec XLEN "$STREAM_KEY")"
  [ "$XLEN" = "$DOC_COUNT" ] && break
  i=$((i + 1))
  sleep 1
done
expect_eq "XLEN $STREAM_KEY" "$DOC_COUNT" "$XLEN"

XRANGE_JSON="$(redis_exec XRANGE "$STREAM_KEY" - +)"
if jq -e 'type == "array"' >/dev/null 2>&1 <<<"$XRANGE_JSON"; then
  ok "XRANGE returned a JSON array"
else
  bad "XRANGE did not return valid JSON"
  summary
fi

expect_eq "stream entries" "$DOC_COUNT" "$(jq -r 'length' <<<"$XRANGE_JSON" 2>/dev/null)"

FIELDS_SHAPE="$(jq -c '[.[] | (.[1] | length)] | unique' <<<"$XRANGE_JSON" 2>/dev/null)"
expect_eq "each entry has exactly one field" "[2]" "$FIELDS_SHAPE"
FIELD_NAMES="$(jq -c '[.[] | .[1][0]] | unique' <<<"$XRANGE_JSON" 2>/dev/null)"
expect_eq "field name is payload" '["payload"]' "$FIELD_NAMES"

PAYLOAD_KEYS="$(jq -c '[.[] | (.[1][1] | fromjson | keys | sort)] | unique' <<<"$XRANGE_JSON" 2>/dev/null)"
expect_eq "payload keys" \
  '[["correlation_id","document_id","enqueued_at","object_key","schema_version"]]' \
  "$PAYLOAD_KEYS"

STREAM_IDS="$(jq -r '.[] | (.[1][1] | fromjson | .document_id)' <<<"$XRANGE_JSON" 2>/dev/null | sort)"
CREATED_SORTED="$(printf '%s\n' "${CREATED_IDS[@]}" | sort)"
if [ "$STREAM_IDS" = "$CREATED_SORTED" ]; then
  ok "the 50 stream document_id values match the 50 created documents"
else
  bad "stream document_id set does not match the created documents"
fi
UNIQUE_STREAM_IDS="$(printf '%s\n' "$STREAM_IDS" | sed '/^$/d' | sort -u | wc -l | tr -d ' ')"
expect_eq "unique document_id values" "$DOC_COUNT" "$UNIQUE_STREAM_IDS"

SAMPLE_PAYLOAD="$(jq -c '.[0][1][1] | fromjson' <<<"$XRANGE_JSON" 2>/dev/null)"
if [ -n "$SAMPLE_PAYLOAD" ] && [ "$SAMPLE_PAYLOAD" != "null" ]; then
  ok "sample payload: $SAMPLE_PAYLOAD"
else
  bad "could not extract a sample payload"
fi

# --- S4. Dedup multi-replica -------------------------------------------------
info "S4. Re-disparar UPLOADED de un documento ya encolado"
SAMPLE_ID="${CREATED_IDS[0]}"
JS="db.documents.updateOne({_id:'$SAMPLE_ID'},{\$set:{status:'PENDING_UPLOAD'}}); db.documents.updateOne({_id:'$SAMPLE_ID'},{\$set:{status:'UPLOADED',updated_at:new Date()}}); print('updated');"
if mongo_eval "$JS" | grep -q 'updated'; then
  ok "document $SAMPLE_ID re-transitioned PENDING_UPLOAD -> UPLOADED"
else
  bad "could not re-transition document $SAMPLE_ID"
fi
RESTATUS="$(mongo_eval "print(db.documents.findOne({_id:'$SAMPLE_ID'}).status)")"
expect_eq "sample document status after re-trigger" "UPLOADED" "$RESTATUS"

AFLEN_OK=1
i=0
while [ "$i" -lt 10 ]; do
  cur="$(redis_exec XLEN "$STREAM_KEY")"
  [ "$cur" = "$DOC_COUNT" ] || AFLEN_OK=0
  i=$((i + 1))
  sleep 1
done
if [ "$AFLEN_OK" -eq 1 ]; then
  ok "XLEN remained $DOC_COUNT after the dedup re-trigger"
else
  bad "XLEN changed after the dedup re-trigger (last=$cur)"
fi

DEDUP_KEYS=()
for id in "${CREATED_IDS[@]}"; do
  DEDUP_KEYS+=("dedup:$id")
done
EXISTS_COUNT="$(redis_exec EXISTS "${DEDUP_KEYS[@]}")"
expect_eq "dedup keys existing" "$DOC_COUNT" "$EXISTS_COUNT"

SAMPLE_TTL="$(redis_exec TTL "dedup:$SAMPLE_ID")"
if [ "$SAMPLE_TTL" -gt 0 ] 2>/dev/null && [ "$SAMPLE_TTL" -le 600 ] 2>/dev/null; then
  ok "dedup TTL for $SAMPLE_ID = ${SAMPLE_TTL}s (0 < TTL <= 600)"
else
  bad "dedup TTL for $SAMPLE_ID is '$SAMPLE_TTL', expected 0 < TTL <= 600"
fi

# --- Rollback ----------------------------------------------------------------
rollback || true

summary
