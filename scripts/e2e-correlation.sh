#!/usr/bin/env bash
# E2E — correlation_id traceability (SPEC §10 / S3-P1-03, scope A).
#
# Verifies against the `full` stack:
#   1. POST /api/v2/documents with X-Correlation-Id -> 201, echoed header
#   2. Presigned POST upload -> MinIO webhook -> Mongo UPLOADED + history
#   3. Redis Streams carries the work message with the correlation_id
#   4. Traefik access log and doc-service logs contain the correlation_id
#   5. No-header request -> doc-service generates a UUID and persists it
#   6. Invalid header -> doc-service replaces it with a UUID (never logs raw)
#   7. Regression: /internal/storage/events is not exposed through Traefik (404)
#
# The extraction worker is not part of this scope (S4-P1-01): when it is not
# running, its check is reported as N/A and does not fail the run.
#
# Usage:
#   scripts/e2e-correlation.sh
#
# Variables (loaded from infra/.env when present):
#   API_BASE_URL   (default https://api.localhost:${TRAEFIK_HTTPS_PORT:-443})
#   E2E_INSECURE   default 1 (mkcert certs are not trusted by the host)
#   E2E_CA_CERT    path to the mkcert CA; overrides trust for TLS
#   E2E_TIMEOUT    seconds to wait for UPLOADED/Redis/log propagation (default 30)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"
SECRETS_DIR="$INFRA_DIR/secrets"

fail=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FAIL] $*"; fail=$((fail + 1)); }
info() { echo "== $* =="; }

summary() {
  echo
  if [ "$fail" -eq 0 ]; then
    echo "E2E correlation OK — traceability verified end to end."
    exit 0
  fi
  echo "E2E correlation with $fail failure(s). Review the [FAIL] lines."
  exit 1
}

# --- Settings -----------------------------------------------------------------
if [ -f "$INFRA_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$INFRA_DIR/.env"
  set +a
fi

TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-443}"
API_BASE_URL="${API_BASE_URL:-https://api.localhost:${TRAEFIK_HTTPS_PORT}}"
E2E_INSECURE="${E2E_INSECURE:-1}"
E2E_TIMEOUT="${E2E_TIMEOUT:-30}"
MONGO_DATABASE="${MONGO_DATABASE:-documents}"
REDIS_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"

COMPOSE=(docker compose -f "$COMPOSE_FILE" --env-file "$INFRA_DIR/.env" --profile full)

CURL_TLS=()
[ "$E2E_INSECURE" = "1" ] && CURL_TLS+=(-k)
[ -n "${E2E_CA_CERT:-}" ] && CURL_TLS+=(--cacert "$E2E_CA_CERT")
CURL_BASE=(curl -sS --max-time 20 "${CURL_TLS[@]}")

# --- Helpers ------------------------------------------------------------------
# Reads a secret file without printing its contents.
load_secret() {
  local value
  value="$(cat "$1" 2>/dev/null)" || return 1
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# Reads the first value for a response header, case-insensitively.
header_value() { # <headers-file> <header-name>
  awk -v name="$2" '
    {
      line = $0
      gsub(/\r$/, "", line)
      if (index(tolower(line), tolower(name) ":") == 1) {
        sub(/^[^:]*:[[:space:]]*/, "", line)
        print line
        exit
      }
    }' "$1"
}

is_uuid() {
  [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

expect_eq() { # <label> <expected> <actual>
  if [ "$2" = "$3" ]; then
    ok "$1 = $3"
  else
    bad "$1: expected '$2', got '$3'"
  fi
}

post_create() { # <document-id> <correlation-or-empty> <headers-file> <body-file>
  local id="$1" corr="$2" hdr="$3" body="$4" code body_json
  local corr_args=()

  body_json="$(jq -n --arg ik "$id" --argjson sz "$FILE_SIZE" \
    '{idempotency_key:$ik, size_bytes:$sz}')"
  [ -n "$corr" ] && corr_args=(-H "X-Correlation-Id: $corr")

  code="$("${CURL_BASE[@]}" -X POST "$API_BASE_URL/api/v2/documents" \
    -H 'Content-Type: application/json' "${corr_args[@]}" \
    -d "$body_json" -D "$hdr" -o "$body" -w '%{http_code}' 2>/dev/null)" || code="000"
  printf '%s' "$code"
}

mongo_doc_json() { # <document-id>
  "${COMPOSE[@]}" exec -T mongo mongosh --quiet \
    -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" \
    --authenticationDatabase "$MONGO_DATABASE" "$MONGO_DATABASE" \
    --eval "var d=db.documents.findOne({_id:'$1'}); print(JSON.stringify(d ? {status:d.status, correlation_id:d.correlation_id, history:(d.history||[]).map(function(h){return {status:h.status, actor:h.actor, correlation_id:h.correlation_id};})} : null));" \
    2>/dev/null
}

redis_stream_head() {
  "${COMPOSE[@]}" exec -T redis-streams redis-cli -a "$REDIS_STREAMS_PASSWORD" \
    --no-auth-warning --raw XRANGE "$REDIS_STREAM_KEY" - + COUNT 20 2>/dev/null
}

redis_stream_tail() {
  "${COMPOSE[@]}" exec -T redis-streams redis-cli -a "$REDIS_STREAMS_PASSWORD" \
    --no-auth-warning --raw XREVRANGE "$REDIS_STREAM_KEY" + - COUNT 20 2>/dev/null
}

log_has() { # <service> <needle>
  "${COMPOSE[@]}" logs --no-color "$1" 2>/dev/null | grep -qF -- "$2"
}

# --- Preflight ----------------------------------------------------------------
info "Preflight"
for t in curl jq openssl docker; do
  command -v "$t" >/dev/null 2>&1 && ok "tool: $t" || bad "missing tool: $t"
done
[ -r "$INFRA_DIR/.env" ] && ok "infra/.env readable" || bad "infra/.env is missing"
for s in mongo_app_password.txt redis_streams_password.txt; do
  [ -r "$SECRETS_DIR/$s" ] && ok "secret readable: secrets/$s" || bad "secret missing: secrets/$s"
done
[ "$fail" -gt 0 ] && { echo; echo "Install the missing tools/files and retry."; summary; }

# Override passwords from Docker secret files (never printed).
MONGO_APP_PASSWORD=""
REDIS_STREAMS_PASSWORD=""
if ! MONGO_APP_PASSWORD="$(load_secret "$SECRETS_DIR/mongo_app_password.txt")"; then
  bad "could not read secrets/mongo_app_password.txt"
fi
if ! REDIS_STREAMS_PASSWORD="$(load_secret "$SECRETS_DIR/redis_streams_password.txt")"; then
  bad "could not read secrets/redis_streams_password.txt"
fi
[ "$fail" -gt 0 ] && summary

if "${CURL_BASE[@]}" "$API_BASE_URL/healthz" >/dev/null 2>&1; then
  ok "doc-service reachable through Traefik: $API_BASE_URL/healthz"
else
  bad "cannot reach $API_BASE_URL/healthz (is the full stack up?)"
  summary
fi

WORK_DIR="$(mktemp -d)"
PDF="$WORK_DIR/fixture.pdf"
trap 'rm -rf "$WORK_DIR"' EXIT
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$PDF"
FILE_SIZE="$(wc -c < "$PDF" | tr -d ' ')"

DOC_ID="$(openssl rand -hex 16)"
CORR="corr-s3p103-$(date -u +%Y%m%dT%H%M%SZ)"

# --- 1. Create with X-Correlation-Id ------------------------------------------
echo
info "1. POST /api/v2/documents with X-Correlation-Id=$CORR"
HDR1="$WORK_DIR/create-corr.hdr"
BODY1="$WORK_DIR/create-corr.json"
CODE1="$(post_create "$DOC_ID" "$CORR" "$HDR1" "$BODY1")"
expect_eq "create HTTP status" "201" "$CODE1"

if ! jq -e . "$BODY1" >/dev/null 2>&1; then
  bad "create response is not valid JSON"
  summary
fi

RESP_ID="$(jq -r '.document_id // ""' "$BODY1")"
UPLOAD_URL="$(jq -r '.upload_url // ""' "$BODY1")"
EXPIRES_IN="$(jq -r '.expires_in // 0' "$BODY1")"
RESP_CORR="$(header_value "$HDR1" "X-Correlation-Id")"

expect_eq "document_id" "$DOC_ID" "$RESP_ID"
expect_eq "response X-Correlation-Id" "$CORR" "$RESP_CORR"
[ "$EXPIRES_IN" -gt 0 ] 2>/dev/null && ok "expires_in = ${EXPIRES_IN}s" || bad "invalid expires_in"
[ -n "$UPLOAD_URL" ] && ok "upload_url returned" || { bad "upload_url missing"; summary; }

# --- 2. Presigned upload ------------------------------------------------------
info "2. Presigned multipart POST to MinIO"
FORM_ARGS=()
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] && FORM_ARGS+=(-F "$k=$v")
done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' "$BODY1")

UPLOAD_CODE="$("${CURL_BASE[@]}" -X POST "$UPLOAD_URL" "${FORM_ARGS[@]}" \
  -F "file=@${PDF};type=application/pdf" -o /dev/null -w '%{http_code}' 2>/dev/null)" \
  || UPLOAD_CODE="000"
case "$UPLOAD_CODE" in
  200|201|204) ok "PDF uploaded (${FILE_SIZE} bytes)" ;;
  *) bad "presigned upload failed (HTTP $UPLOAD_CODE)" ;;
esac

# --- 3. Mongo transition + history -------------------------------------------
info "3. Mongo documents status/history"
DOC_JSON=""
i=0
while [ "$i" -lt "$E2E_TIMEOUT" ]; do
  DOC_JSON="$(mongo_doc_json "$DOC_ID")"
  [ "$(jq -r '.status // empty' <<<"$DOC_JSON" 2>/dev/null)" = "UPLOADED" ] && break
  i=$((i + 1))
  sleep 1
done

STATUS="$(jq -r '.status // ""' <<<"$DOC_JSON" 2>/dev/null)"
MONGO_CORR="$(jq -r '.correlation_id // ""' <<<"$DOC_JSON" 2>/dev/null)"
HIST_COUNT="$(jq -r --arg c "$CORR" \
  '[.history[]? | select(.status == "UPLOADED" and .actor == "minio-webhook" and .correlation_id == $c)] | length' \
  <<<"$DOC_JSON" 2>/dev/null)"

expect_eq "Mongo status" "UPLOADED" "$STATUS"
expect_eq "Mongo correlation_id" "$CORR" "$MONGO_CORR"
if [ "${HIST_COUNT:-0}" -ge 1 ] 2>/dev/null; then
  ok "history has UPLOADED / minio-webhook / $CORR"
else
  bad "history lacks UPLOADED / minio-webhook / $CORR"
fi

# --- 4. Redis Streams ---------------------------------------------------------
info "4. Redis Streams payload"
REDIS_OUT=""
i=0
while [ "$i" -lt "$E2E_TIMEOUT" ]; do
  REDIS_OUT="$(redis_stream_head)"
  if grep -qF -- "$CORR" <<<"$REDIS_OUT" && grep -qF -- "$DOC_ID" <<<"$REDIS_OUT"; then
    break
  fi
  i=$((i + 1))
  sleep 1
done

# The requested XRANGE window starts at the oldest entry; on a long-lived
# stream the new message may be outside it, so fall back to the newest window.
if ! grep -qF -- "$CORR" <<<"$REDIS_OUT" || ! grep -qF -- "$DOC_ID" <<<"$REDIS_OUT"; then
  REDIS_OUT="$(redis_stream_tail)"
fi

if grep -qF -- "$CORR" <<<"$REDIS_OUT" && grep -qF -- "$DOC_ID" <<<"$REDIS_OUT"; then
  ok "stream contains correlation_id and document_id"
else
  bad "stream does not contain correlation_id/document_id in the inspected window"
fi

# --- 5. Traefik and doc-service logs -----------------------------------------
info "5. Logs"
TRAEFIK_OK=0
DOCSVC_OK=0
i=0
while [ "$i" -lt "$E2E_TIMEOUT" ]; do
  TRAEFIK_OK=0
  DOCSVC_OK=0
  log_has traefik "$CORR" && TRAEFIK_OK=1
  log_has doc-service "$CORR" && DOCSVC_OK=1
  [ "$TRAEFIK_OK" = "1" ] && [ "$DOCSVC_OK" = "1" ] && break
  i=$((i + 1))
  sleep 1
done
[ "$TRAEFIK_OK" = "1" ] && ok "Traefik access log contains correlation_id" || bad "Traefik access log lacks correlation_id"
[ "$DOCSVC_OK" = "1" ] && ok "doc-service log contains correlation_id" || bad "doc-service log lacks correlation_id"

# --- 6. Worker (deferred to S4-P1-01) ----------------------------------------
info "6. Extraction worker"
if "${COMPOSE[@]}" ps --services --filter status=running 2>/dev/null | grep -qx 'extraction-worker'; then
  if log_has extraction-worker "$CORR"; then
    ok "worker log contains correlation_id"
  else
    bad "worker is running but its log lacks correlation_id"
  fi
else
  echo "N/A: worker no desplegado; contrato verificado en doc-service; E2E real S4-P1-01"
fi

# --- 7. No header -> generated UUID ------------------------------------------
info "7. Create without X-Correlation-Id"
DOC_ID2="$(openssl rand -hex 16)"
HDR2="$WORK_DIR/create-nohdr.hdr"
BODY2="$WORK_DIR/create-nohdr.json"
CODE2="$(post_create "$DOC_ID2" "" "$HDR2" "$BODY2")"
expect_eq "no-header create HTTP status" "201" "$CODE2"
RESP2_CORR="$(header_value "$HDR2" "X-Correlation-Id")"
if is_uuid "$RESP2_CORR"; then
  ok "response X-Correlation-Id is a UUID ($RESP2_CORR)"
else
  bad "response X-Correlation-Id is missing or not a UUID"
fi
DOC2_JSON="$(mongo_doc_json "$DOC_ID2")"
MONGO2_CORR="$(jq -r '.correlation_id // ""' <<<"$DOC2_JSON" 2>/dev/null)"
expect_eq "Mongo (no header) correlation_id" "$RESP2_CORR" "$MONGO2_CORR"

# --- 8. Invalid header -> generated UUID, no raw leak ------------------------
info "8. Create with invalid X-Correlation-Id"
DOC_ID3="$(openssl rand -hex 16)"
HDR3="$WORK_DIR/create-invalid.hdr"
BODY3="$WORK_DIR/create-invalid.json"
INVALID_SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
CODE3="$(post_create "$DOC_ID3" "bad value" "$HDR3" "$BODY3")"
expect_eq "invalid-header create HTTP status" "201" "$CODE3"
RESP3_CORR="$(header_value "$HDR3" "X-Correlation-Id")"
if [ "$RESP3_CORR" != "bad value" ]; then
  ok "raw invalid header is not echoed back"
else
  bad "response echoed the raw invalid header"
fi
if is_uuid "$RESP3_CORR"; then
  ok "response X-Correlation-Id is a UUID ($RESP3_CORR)"
else
  bad "response X-Correlation-Id is missing or not a UUID"
fi
DOC3_JSON="$(mongo_doc_json "$DOC_ID3")"
MONGO3_CORR="$(jq -r '.correlation_id // ""' <<<"$DOC3_JSON" 2>/dev/null)"
expect_eq "Mongo (invalid header) correlation_id" "$RESP3_CORR" "$MONGO3_CORR"
if [ "$MONGO3_CORR" != "bad value" ]; then
  ok "Mongo stores the generated UUID, not the raw invalid value"
else
  bad "Mongo stored the raw invalid value"
fi
if [ "$MONGO3_CORR" != "$CORR" ]; then
  ok "generated UUID differs from the valid client correlation_id"
else
  bad "Mongo reused the valid client correlation_id for an invalid header"
fi

# doc-service never logs the raw inbound value. Traefik's access log may keep
# it because the header field is configured with `keep` (documented behavior).
sleep 1
if "${COMPOSE[@]}" logs --no-color --since "$INVALID_SINCE" doc-service 2>/dev/null | grep -qF -- "bad value"; then
  bad "doc-service logs contain the raw invalid correlation value"
else
  ok "doc-service logs do not contain the raw invalid value"
fi

# --- 9. Regression: /internal is not public ----------------------------------
info "9. Regression: /internal/storage/events through Traefik"
INTERNAL_CODE="$("${CURL_BASE[@]}" -o /dev/null -w '%{http_code}' \
  "$API_BASE_URL/internal/storage/events" 2>/dev/null)" || INTERNAL_CODE="000"
expect_eq "GET /internal/storage/events" "404" "$INTERNAL_CODE"

summary
