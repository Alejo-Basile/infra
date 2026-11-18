#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

compose() { docker compose -p infra --env-file infra/.env -f infra/compose/docker-compose.yml "$@"; }

PORT="$(grep -E '^TRAEFIK_HTTPS_PORT=' infra/.env | head -1 | cut -d= -f2-)"
PORT="${PORT:-8543}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

FAIL=0
SKIP=0

pass() { echo "PASS $1 $2"; }
fail() { echo "FAIL $1 $2"; FAIL=1; }
skip() { echo "SKIP $1 $2 ($3)"; SKIP=$((SKIP+1)); }

run_step() {
  # $1 number, $2 desc, $3 timeout seconds, rest command
  local n="$1"; shift
  local desc="$1"; shift
  local timeout_s="$1"; shift
  if timeout "${timeout_s}s" bash -c "$*" >/dev/null 2>&1; then
    pass "$n" "$desc"
  else
    fail "$n" "$desc"
  fi
}

# Network from consul-agent
NET="$(docker inspect -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{end}}' "$(compose ps -q consul-agent)" 2>/dev/null || echo infra_internal)"

# Step 1
if timeout 30s bash -c 'cd "$0" && docker compose -p infra --env-file infra/.env -f infra/compose/docker-compose.yml --profile discovery config --quiet' "$ROOT" >/dev/null 2>&1; then
  pass 1 "compose config quiet"
else
  fail 1 "compose config quiet"
fi

# Step 2 leader
leader_code="$(timeout 30s docker exec "$(compose ps -q consul-agent)" sh -c 'curl -s -o /tmp/l -w "%{http_code}" --cacert /run/secrets/consul_ca_cert https://consul:8501/v1/status/leader' 2>/dev/null || echo "000")"
leader_body="$(timeout 30s docker exec "$(compose ps -q consul-agent)" sh -c 'cat /tmp/l' 2>/dev/null || echo "")"
if [[ "$leader_code" == "200" && -n "$leader_body" && "$leader_body" != '""' ]]; then
  pass 2 "leader elected"
else
  fail 2 "leader elected"
fi

# Step 3 ACL matrix
anon_code="$(timeout 30s docker exec "$(compose ps -q consul-agent)" sh -c 'curl -s -o /dev/null -w "%{http_code}" --cacert /run/secrets/consul_ca_cert https://consul:8501/v1/kv/config/doc-service/max_pdf_bytes' 2>/dev/null || echo "000")"
doc_code="$(timeout 30s docker run --rm --network "$NET" --entrypoint /bin/sh \
  -v "$ROOT/infra/secrets/consul_ca_cert.pem:/ca.pem:ro" \
  -v "$ROOT/infra/secrets/consul_doc_service_token.txt:/tok:ro" \
  curlimages/curl:8.10.1 -c 'TOKEN=$(cat /tok); curl -s -o /dev/null -w "%{http_code}" -H "X-Consul-Token: $TOKEN" --cacert /ca.pem https://consul:8501/v1/kv/config/doc-service/max_pdf_bytes' 2>/dev/null || echo "000")"
doc_forbidden_code="$(timeout 30s docker run --rm --network "$NET" --entrypoint /bin/sh \
  -v "$ROOT/infra/secrets/consul_ca_cert.pem:/ca.pem:ro" \
  -v "$ROOT/infra/secrets/consul_doc_service_token.txt:/tok:ro" \
  curlimages/curl:8.10.1 -c 'TOKEN=$(cat /tok); curl -s -o /dev/null -w "%{http_code}" -H "X-Consul-Token: $TOKEN" --cacert /ca.pem https://consul:8501/v1/kv/config/rate-limiter/sensitive_routes' 2>/dev/null || echo "000")"

if [[ "$anon_code" == "403" && "$doc_code" == "200" && "$doc_forbidden_code" == "403" ]]; then
  pass 3 "ACL matrix"
else
  fail 3 "ACL matrix (anon=$anon_code doc=$doc_code forbidden=$doc_forbidden_code)"
fi

# Step 4 registration
REG_OK=1
IDS=""
for svc in svc-doc-service svc-extraction-worker; do
  health="$(timeout 60s docker exec "$(compose ps -q consul-agent)" sh -c "TOKEN=\$(cat /run/secrets/consul_operator_token 2>/dev/null || cat /run/secrets/consul_operator_token.txt 2>/dev/null); curl -s -H \"X-Consul-Token: \$TOKEN\" --cacert /run/secrets/consul_ca_cert https://consul:8501/v1/health/service/$svc" 2>/dev/null || echo "[]")"
  count="$(echo "$health" | jq 'length' 2>/dev/null || echo 0)"
  if [[ "$count" -lt 1 ]]; then REG_OK=0; fi
  echo "$health" | jq -r '.[].Checks[].Status' 2>/dev/null | grep -v '^passing$' >/dev/null && REG_OK=0
  ids="$(echo "$health" | jq -r '.[].Service.ID' 2>/dev/null)"
  IDS="$IDS $ids"
done
# distinct
distinct="$(echo "$IDS" | tr ' ' '\n' | grep -v '^$' | sort -u | wc -l)"
total="$(echo "$IDS" | tr ' ' '\n' | grep -v '^$' | wc -l)"
if [[ "$REG_OK" == "1" && "$distinct" == "$total" && "$total" -gt 0 ]]; then
  pass 4 "registration"
else
  fail 4 "registration (ok=$REG_OK distinct=$distinct total=$total)"
fi

# Step 5 KV matches JSON
kv="$(timeout 60s docker exec "$(compose ps -q consul-agent)" sh -c 'TOKEN=$(cat /run/secrets/consul_operator_token 2>/dev/null || cat /run/secrets/consul_operator_token.txt 2>/dev/null); curl -s -H "X-Consul-Token: $TOKEN" --cacert /run/secrets/consul_ca_cert "https://consul:8501/v1/kv/config/?recurse"' 2>/dev/null || echo "[]")"
# build expected
expected_file="$WORK/expected.txt"
actual_file="$WORK/actual.txt"
: > "$expected_file"
for f in infra/compose/consul/kv/*.json; do
  svc="$(basename "$f" .json)"
  jq -r 'to_entries[] | "config/'"$svc"'/\(.key)=\(.value | tostring)"' "$f" >> "$expected_file"
done
echo "$kv" | jq -r '.[] | select(.Key | startswith("config/meta/") | not) | "\(.Key)=\(.Value | @base64d)"' 2>/dev/null | sort > "$actual_file"
sort "$expected_file" > "$expected_file.sorted"
# Compare keys only for service prefixes
if diff -q <(sort "$expected_file") "$actual_file" >/dev/null 2>&1; then
  pass 5 "KV matches JSON"
else
  fail 5 "KV matches JSON"
fi

# Step 6 Prometheus SD
prom_cid="$(compose ps -q prometheus)"
targets="$(timeout 30s docker exec "$prom_cid" wget -qO- http://127.0.0.1:9090/api/v1/targets 2>/dev/null || echo '{}')"
app_targets="$(echo "$targets" | jq '.data.activeTargets[] | select(.labels.job=="app-services")' 2>/dev/null)"
count="$(echo "$app_targets" | jq -s 'length' 2>/dev/null || echo 0)"
up_count="$(echo "$app_targets" | jq -s '[.[] | select(.health=="up")] | length' 2>/dev/null || echo 0)"
distinct_inst="$(echo "$app_targets" | jq -s '[.[].labels.instance] | unique | length' 2>/dev/null || echo 0)"
if [[ "$count" -ge 2 && "$count" == "$up_count" && "$distinct_inst" == "$count" ]]; then
  pass 6 "Prometheus SD"
else
  fail 6 "Prometheus SD (count=$count up=$up_count distinct=$distinct_inst)"
fi

# Step 7 UI
if [[ -f infra/secrets/consul_ui_password.txt ]]; then
  curlcfg="$WORK/curl.cfg"
  printf 'user = "consul:%s"\n' "$(cat infra/secrets/consul_ui_password.txt)" > "$curlcfg"
  chmod 0600 "$curlcfg"
  code_noauth="$(timeout 30s curl -sk -o /dev/null -w '%{http_code}' --resolve "consul.localhost:${PORT}:127.0.0.1" "https://consul.localhost:${PORT}/" 2>/dev/null || echo "000")"
  code_auth="$(timeout 30s curl -sk -o /dev/null -w '%{http_code}' -K "$curlcfg" --resolve "consul.localhost:${PORT}:127.0.0.1" "https://consul.localhost:${PORT}/" 2>/dev/null || echo "000")"
  if [[ "$code_noauth" == "401" && "$code_auth" == "200" ]]; then
    pass 7 "UI"
  else
    fail 7 "UI (noauth=$code_noauth auth=$code_auth) — C09 no implementado"
  fi
else
  fail 7 "UI — C09 no implementado (falta consul_ui_password.txt)"
fi

# Step 8 guardrails
if [[ -r infra/scripts/verify-consul-boundaries.sh ]]; then
  if timeout 30s bash infra/scripts/verify-consul-boundaries.sh >/dev/null 2>&1; then
    pass 8 "guardrails"
  else
    fail 8 "guardrails"
  fi
else
  skip 8 "guardrails" "C25 no implementado; fuera de alcance de C22"
fi

# Step 9 summary
echo "FAIL=$FAIL SKIP=$SKIP"
if [[ "$FAIL" -gt 0 ]]; then exit 1; fi
exit 0
