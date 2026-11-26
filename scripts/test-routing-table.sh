#!/usr/bin/env bash
# Verifica que cada ruta del inventario cae en el router esperado.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

compose() { docker compose -p infra --env-file infra/.env -f infra/compose/docker-compose.yml "$@"; }

PORT="$(grep -E '^TRAEFIK_HTTPS_PORT=' infra/.env | head -1 | cut -d= -f2-)"
PORT="${PORT:-443}"

CID="$(compose ps -q traefik)"

jq_router() {
  # args: path method — the probe's log line is in the tail, so scan only the
  # last 2000 lines. Reading the whole access log per case made this suite
  # exceed its 120 s budget once the 9-hour Traefik log grew large.
  local path="$1" method="$2"
  docker logs --tail 2000 "$CID" 2>&1 | jq -R 'fromjson?' 2>/dev/null | jq -s --arg p "$path" --arg m "$method" '
    [.[] | select(.RequestPath == $p and .RequestMethod == $m)] | last | .RouterName
  ' -r
}

FAIL=0
run_case() {
  local method="$1" path="$2" expected="$3"
  local router code
  code="$(curl -skS -o /dev/null -w "%{http_code}" --resolve "api.localhost:${PORT}:127.0.0.1" -X "$method" "https://api.localhost:${PORT}${path}" || true)"
  sleep 0.4
  router="$(jq_router "$path" "$method")"
  if [[ "$router" == "$expected" ]]; then
    echo "OK   $method $path -> $router (HTTP $code)"
  else
    echo "FALLA $method $path -> got='${router:-<vacío>}' expected='$expected' (HTTP $code)"
    FAIL=1
  fi
}

run_case "GET" "/health" "r-inv-health@file"
run_case "GET" "/health/ready" "r-inv-health-ready@file"
run_case "POST" "/pdf/process" "r-inv-pdf-process@file"
run_case "GET" "/registros" "r-inv-registros@file"
run_case "GET" "/registros/hash/$(printf 'a%.0s' $(seq 1 64))" "r-inv-registros-hash@file"
run_case "GET" "/registros/11111111-2222-4333-8444-555555555555" "r-inv-registros-id@file"
run_case "PUT" "/registros/11111111-2222-4333-8444-555555555555" "r-inv-registros-put@file"
run_case "DELETE" "/registros/11111111-2222-4333-8444-555555555555" "r-inv-registros-delete@file"
run_case "GET" "/docs" "r-inv-docs@file"
run_case "GET" "/redoc" "r-inv-redoc@file"
run_case "GET" "/openapi.json" "r-inv-openapi@file"
run_case "GET" "/healthz" "r-doc-healthz@file"
# case 13: curl con query, match por path base
code="$(curl -skS -o /dev/null -w "%{http_code}" --resolve "api.localhost:${PORT}:127.0.0.1" "https://api.localhost:${PORT}/api/v2/documents?page_size=1" || true)"
sleep 0.4
router="$(jq_router "/api/v2/documents?page_size=1" "GET")"
if [[ "$router" == "r-api-v2@file" ]]; then echo "OK   GET /api/v2/documents?page_size=1 -> $router (HTTP $code)"; else echo "FALLA GET /api/v2/documents?page_size=1 -> got='${router:-<vacío>}' expected='r-api-v2@file' (HTTP $code)"; FAIL=1; fi

# /no-existe -> 404 y sin router
code="$(curl -skS -o /dev/null -w "%{http_code}" --resolve "api.localhost:${PORT}:127.0.0.1" "https://api.localhost:${PORT}/no-existe" || true)"
if [[ "$code" == "404" ]]; then
  echo "OK   GET /no-existe -> 404 (sin catch-all)"
else
  echo "FALLA GET /no-existe -> HTTP $code (se esperaba 404)"
  FAIL=1
fi

# s3
code="$(curl -skS -o /dev/null -w "%{http_code}" --resolve "s3.localhost:${PORT}:127.0.0.1" "https://s3.localhost:${PORT}/minio/health/live" || true)"
router="$(jq_router "/minio/health/live" "GET")"
if [[ "$code" == "200" && "$router" == "s3-api@file" ]]; then
  echo "OK   GET /minio/health/live (s3.localhost) -> $router (HTTP $code)"
else
  echo "FALLA s3 -> got='${router:-<vacío>}' code=$code"
  FAIL=1
fi

exit "$FAIL"
