#!/usr/bin/env bash
# E2E-01 — Flujo de subida prefirmada (SPEC §3.1 / §5.2) — S1
#
# Verifica de punta a punta, contra el stack `full`:
#   1. POST /api/v2/documents  -> 201 con URL prefirmada POST (contrato v2)
#   2. La URL prefirmada se firma con el host PUBLICO (s3.localhost:<puerto>)
#   3. Subida directa a MinIO via POST prefirmada (el PDF NO pasa por el gateway)
#   4. MinIO emite ObjectCreated:Put -> webhook interno -> PENDING_UPLOAD => UPLOADED
#   5. El change stream relay publica el trabajo en Redis Streams (XADD)
#   6. Idempotencia: recrear el mismo documento devuelve el existente (200)
#   7. Deduplicacion: un webhook repetido NO genera un segundo trabajo
#
# Uso:
#   scripts/bootstrap.sh                       # genera credenciales + certs
#   docker compose -f compose/docker-compose.yml --profile full up -d --build
#   scripts/e2e-01.sh
#
# Variables (se leen de infra/.env si existen):
#   API_BASE_URL   (default https://api.localhost:${TRAEFIK_HTTPS_PORT:-443})
#   E2E_INSECURE=1 para omitir la verificacion TLS (certs mkcert no confiados)
#   E2E_CA_CERT=/ruta/ca.pem para fijar la CA de mkcert
#   E2E_TIMEOUT    segundos de espera por estado UPLOADED (default 30)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="$INFRA_DIR/compose/docker-compose.yml"

# Cargar .env (sin sobreescribir lo ya exportado).
if [ -f "$INFRA_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$INFRA_DIR/.env"
  set +a
fi

TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-443}"
API_BASE_URL="${API_BASE_URL:-https://api.localhost:${TRAEFIK_HTTPS_PORT}}"
E2E_TIMEOUT="${E2E_TIMEOUT:-30}"
MONGO_DATABASE="${MONGO_DATABASE:-documents}"
REDIS_STREAM_KEY="${REDIS_STREAM_KEY:-stream:pdf-processing}"

CURL_TLS=()
[ "${E2E_INSECURE:-0}" = "1" ] && CURL_TLS+=(-k)
[ -n "${E2E_CA_CERT:-}" ] && CURL_TLS+=(--cacert "$E2E_CA_CERT")
CURL=(curl -sS --fail-with-body --max-time 20 "${CURL_TLS[@]}")

fail=0
ok()   { echo "  [OK]   $*"; }
bad()  { echo "  [FALLA] $*"; fail=$((fail + 1)); }
info() { echo "== $* =="; }

# --- Helpers ------------------------------------------------------------------
mongo_status() {
  docker exec infra-mongo-1 mongosh --quiet \
    -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" --authenticationDatabase "$MONGO_DATABASE" \
    "$MONGO_DATABASE" --eval "var d=db.documents.findOne({_id:'$1'}); print(d?d.status:'MISSING')" \
    2>/dev/null
}

xlen() {
  docker exec infra-redis-streams-1 redis-cli -a "$REDIS_STREAMS_PASSWORD" --no-auth-warning \
    XLEN "$REDIS_STREAM_KEY" 2>/dev/null
}

wait_status() { # <id> <esperado> <timeout>
  local id="$1" want="$2" t="$3" i=0 got=""
  while [ "$i" -lt "$t" ]; do
    got="$(mongo_status "$id")"
    [ "$got" = "$want" ] && { echo "$got"; return 0; }
    i=$((i + 1)); sleep 1
  done
  echo "$got"; return 1
}

# --- Preflight ----------------------------------------------------------------
info "Preflight"
for t in curl jq openssl docker; do
  command -v "$t" >/dev/null 2>&1 && ok "tool: $t" || { bad "falta la herramienta: $t"; }
done
[ "$fail" -gt 0 ] && { echo; echo "Instala las herramientas faltantes y reintenta."; exit 2; }

if "${CURL[@]}" "$API_BASE_URL/healthz" >/dev/null 2>&1; then
  ok "doc-service alcanzable via Traefik: $API_BASE_URL/healthz"
else
  bad "no se pudo alcanzar $API_BASE_URL/healthz"
  echo
  echo "  El stack `full` debe estar arriba con doc-service. Bloqueadores conocidos:"
  echo "   CI-A (P2) Redis con password  -> sin esto doc-service NO arranca"
  echo "   CI-B (P2) presign con host publico"
  echo "   CI-C (P1) Dockerfile multi-stage"
  echo "   CI-D (P2) parseo del payload real de MinIO (s3 anidado en Records)"
  echo "  Levanta con: docker compose -f compose/docker-compose.yml --profile full up -d --build"
  exit 2
fi

# --- Fixture PDF --------------------------------------------------------------
PDF="$(mktemp --suffix=.pdf)"
trap 'rm -f "$PDF"' EXIT
printf '%%PDF-1.4\n1 0 obj<</Type/Catalog>>endobj\ntrailer<</Root 1 0 R>>\n%%%%EOF\n' > "$PDF"
FILE_SIZE="$(wc -c < "$PDF" | tr -d ' ')"
DOC_ID="$(openssl rand -hex 16)"
CORR="e2e-$(date -u +%Y%m%dT%H%M%SZ)"

echo
info "1. POST $API_BASE_URL/api/v2/documents (idempotency_key=$DOC_ID)"
CREATE_BODY="$(jq -n --arg ik "$DOC_ID" --argjson sz "$FILE_SIZE" '{idempotency_key:$ik, size_bytes:$sz}')"
CREATE_RESP="$("${CURL[@]}" -X POST "$API_BASE_URL/api/v2/documents" \
  -H 'Content-Type: application/json' -H "X-Correlation-Id: $CORR" -d "$CREATE_BODY" 2>/dev/null)" \
  || { bad "POST create fallo"; exit 1; }

echo "$CREATE_RESP" | jq . >/dev/null 2>&1 || { bad "respuesta no es JSON"; echo "$CREATE_RESP"; exit 1; }
RESP_ID="$(jq -r '.document_id' <<<"$CREATE_RESP")"
UPLOAD_URL="$(jq -r '.upload_url' <<<"$CREATE_RESP")"
EXPIRES_IN="$(jq -r '.expires_in' <<<"$CREATE_RESP")"
[ "$RESP_ID" = "$DOC_ID" ] && ok "document_id = idempotency_key ($RESP_ID)" || bad "document_id inesperado: $RESP_ID"
[ "$EXPIRES_IN" -gt 0 ] 2>/dev/null && ok "expires_in = ${EXPIRES_IN}s" || bad "expires_in invalido"

info "2. Host publico de la URL prefirmada (CI-B)"
case "$UPLOAD_URL" in
  *"s3.localhost"*) ok "upload_url apunta a s3.localhost" ;;
  *) bad "upload_url NO usa el host publico: $UPLOAD_URL (ver CI-B)" ;;
esac

# --- Estado inicial -----------------------------------------------------------
info "3. Estado inicial (Mongo / Redis)"
BEFORE_STATUS="$(mongo_status "$DOC_ID")"
[ "$BEFORE_STATUS" = "PENDING_UPLOAD" ] && ok "Mongo status = PENDING_UPLOAD" || bad "Mongo status = $BEFORE_STATUS (esperado PENDING_UPLOAD)"
XLEN_BEFORE="$(xlen)"
echo "  XLEN($REDIS_STREAM_KEY) antes = ${XLEN_BEFORE:-?}"

# --- Subida prefirmada --------------------------------------------------------
info "4. Subida directa a MinIO (multipart POST prefirmado)"
FORM_ARGS=()
while IFS=$'\t' read -r k v; do
  [ -n "$k" ] && FORM_ARGS+=(-F "$k=$v")
done < <(jq -r '.form_fields | to_entries[] | [.key, .value] | @tsv' <<<"$CREATE_RESP")

if "${CURL[@]}" -X POST "$UPLOAD_URL" "${FORM_ARGS[@]}" -F "file=@${PDF};type=application/pdf" >/dev/null 2>&1; then
  ok "objeto subido (${FILE_SIZE} bytes)"
else
  bad "la subida prefirmada fallo (posible SignatureDoesNotMatch -> CI-B)"
  echo "$CREATE_RESP" | jq '{document_id, upload_url, expires_in}' 2>/dev/null
fi

# --- Webhook -> UPLOADED ------------------------------------------------------
info "5. Transicion PENDING_UPLOAD -> UPLOADED (webhook de MinIO)"
AFTER_STATUS="$(wait_status "$DOC_ID" UPLOADED "$E2E_TIMEOUT")"
if [ "$AFTER_STATUS" = "UPLOADED" ]; then
  ok "Mongo status = UPLOADED"
else
  bad "Mongo status = $AFTER_STATUS tras ${E2E_TIMEOUT}s (webhook no procesado)"
  echo "  Causa probable: CI-D (el handler espera 's3' en la raiz, pero MinIO lo anida en Records[0])."
  docker compose -f "$COMPOSE_FILE" --profile full logs --tail=20 doc-service 2>/dev/null | sed 's/^/    /'
fi

# --- Relay -> Redis Streams ---------------------------------------------------
info "6. Publicacion del trabajo en Redis Streams (relay/change stream)"
XLEN_AFTER="${XLEN_BEFORE:-0}"
i=0
while [ "$i" -lt "$E2E_TIMEOUT" ] && [ "${XLEN_AFTER:-0}" -le "${XLEN_BEFORE:-0}" ]; do
  sleep 1; XLEN_AFTER="$(xlen)"; i=$((i + 1))
done
if [ "${XLEN_AFTER:-0}" -gt "${XLEN_BEFORE:-0}" ]; then
  ok "XADD observado: XLEN ${XLEN_BEFORE} -> ${XLEN_AFTER}"
else
  bad "XLEN no aumento (antes=${XLEN_BEFORE:-?}, despues=${XLEN_AFTER:-?})"
fi

# --- Idempotencia de creacion -------------------------------------------------
info "7. Idempotencia: repetir POST con la misma clave"
IDEM_CODE="$("${CURL[@]}" -o /dev/null -w '%{http_code}' -X POST "$API_BASE_URL/api/v2/documents" \
  -H 'Content-Type: application/json' -d "$CREATE_BODY" 2>/dev/null)"
[ "$IDEM_CODE" = "200" ] && ok "segundo POST devuelve 200 (existente)" || bad "segundo POST devuelve $IDEM_CODE (esperado 200)"

# --- Deduplicacion de webhook -------------------------------------------------
info "8. Deduplicacion: re-subir el mismo objeto (segundo ObjectCreated:Put)"
"${CURL[@]}" -X POST "$UPLOAD_URL" "${FORM_ARGS[@]}" -F "file=@${PDF};type=application/pdf" >/dev/null 2>&1 \
  && ok "objeto re-subido (mismo key)" || bad "no se pudo re-subir para el test de dedup"
sleep 5
XLEN_DEDUP="$(xlen)"
if [ "${XLEN_DEDUP:-0}" -eq "${XLEN_AFTER:-0}" ]; then
  ok "webhook repetido NO genero trabajo nuevo (XLEN estable en ${XLEN_DEDUP})"
else
  bad "XLEN cambio tras el webhook repetido: ${XLEN_AFTER} -> ${XLEN_DEDUP}"
fi

# --- Resumen ------------------------------------------------------------------
echo
if [ "$fail" -eq 0 ]; then
  echo "E2E-01 OK — flujo de subida prefirmada verificado de punta a punta."
else
  echo "E2E-01 con $fail fallo(s). Revisa las lineas [FALLA]."
  exit 1
fi
