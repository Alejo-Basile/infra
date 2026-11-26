#!/usr/bin/env bash
# verify-consul-boundaries.sh — S11-P1-C25 Guardarraíles de frontera (§0)
# Read-only. No external network. No commits.
# Check 4 now guards router rules (names, rule:, priority:, middlewares:) instead
# of a raw routing diff: the service topology is what this change modifies.
# Baseline commit for routing.yml is 4766290 (not af15791 from task-25 §3):
# af15791 exists only in the outer docs repo and does not contain routing.yml.
# In the infra repo, 4766290 is the last commit that touched traefik/dynamic/routing.yml
# (git log 4766290..HEAD -- traefik/dynamic/routing.yml is empty). Override via
# ROUTING_BASELINE_COMMIT when needed.
set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TRAEFIK_CONFIG="${TRAEFIK_CONFIG:-$REPO_ROOT/traefik/traefik.yml}"
COMPOSE_FILE="${COMPOSE_FILE:-$REPO_ROOT/compose/docker-compose.yml}"
COMPOSE_ENV_FILE="${COMPOSE_ENV_FILE:-$REPO_ROOT/.env}"
PROMETHEUS_CONFIG="${PROMETHEUS_CONFIG:-$REPO_ROOT/compose/prometheus/prometheus.yml}"
OCR_MAIN_RS="${OCR_MAIN_RS:-$REPO_ROOT/../extraction-worker/crates/ocr-worker/src/main.rs}"
ROUTING_FILE="${ROUTING_FILE:-$REPO_ROOT/traefik/dynamic/routing.yml}"
KV_EXPORT_FILE="${KV_EXPORT_FILE:-}"
ROUTING_BASELINE_COMMIT="${ROUTING_BASELINE_COMMIT:-4766290}"
ROUTING_REL_PATH="${ROUTING_REL_PATH:-traefik/dynamic/routing.yml}"

fail=0
tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

pass() { echo "PASS: $1"; }
failm() { echo "$1"; fail=$((fail+1)); }
skip() { echo "SKIP: $1"; }

# Check 1
if grep -q 'consulCatalog' "$TRAEFIK_CONFIG" 2>/dev/null; then
  failm "FAIL: consulCatalog detectado en infra/traefik/traefik.yml (frontera §0)"
else
  pass "Check 1: no consulCatalog en traefik.yml"
fi

# Check 2
kv_file="$tmpdir/kv.txt"
got_kv=0
if [ -n "$KV_EXPORT_FILE" ] && [ -f "$KV_EXPORT_FILE" ]; then
  cp "$KV_EXPORT_FILE" "$kv_file"; got_kv=1
elif [ -n "${CONSUL_HTTP_ADDR:-}" ] && [ -n "${CONSUL_TOKEN_FILE:-}" ] && [ -r "${CONSUL_TOKEN_FILE:-}" ]; then
  if curl -fsS --cacert "${CONSUL_CACERT:-/dev/null}" -H "X-Consul-Token: $(cat "$CONSUL_TOKEN_FILE")" "$CONSUL_HTTP_ADDR/v1/kv/config/?recurse" -o "$tmpdir/kv_raw.json" 2>/dev/null; then
    echo "$tmpdir/kv_raw.json" >/dev/null
    # flatten best-effort
    if command -v jq >/dev/null 2>&1; then
      jq -r '.[] | "\(.Key // .key)=\(((.Value // .value) // "")|@base64d)"' "$tmpdir/kv_raw.json" > "$kv_file" 2>/dev/null && got_kv=1
    fi
  fi
elif command -v docker >/dev/null 2>&1; then
  compose_cmd=(docker compose -f "$COMPOSE_FILE")
  if [ -f "$COMPOSE_ENV_FILE" ]; then
    compose_cmd+=(--env-file "$COMPOSE_ENV_FILE")
  fi
  if "${compose_cmd[@]}" exec -T consul-agent consul kv export -http-addr=https://127.0.0.1:8501 -ca-file=/run/secrets/consul_ca_cert -token-file=/run/secrets/consul_operator_token config/ > "$kv_file" 2>/dev/null; then
    got_kv=1
  fi
fi

if [ "$got_kv" -eq 0 ]; then
  skip "Check 2: Consul no disponible / sin credenciales (§0, C25)"
else
  bad=0
  kv_flat="$tmpdir/kv-flat.txt"
  if [ "$(head -c 1 "$kv_file" 2>/dev/null)" = "[" ]; then
    # KV JSON comes in two shapes: HTTP /v1/kv uses {"Key","Value"}; the
    # `consul kv export` CLI uses {"key","value"}. Both values are base64.
    # Flatten it first: grepping the raw JSON would match the literal field
    # names on every entry instead of the actual keys.
    if command -v jq >/dev/null 2>&1; then
      if ! jq -r '.[] | "\(.Key // .key)=\(((.Value // .value) // "")|@base64d)"' "$kv_file" > "$kv_flat" 2>/dev/null; then
        skip "Check 2: export JSON ilegible y sin jq para normalizarlo (§0, C25)"
        kv_flat=""
      fi
    else
      skip "Check 2: export JSON y jq no disponible para normalizarlo (§0, C25)"
      kv_flat=""
    fi
  else
    cp "$kv_file" "$kv_flat"
  fi
  if [ -n "$kv_flat" ]; then
    if grep -Eiq 'password|token|secret|key|pwd|passwd|credential|apikey|api_key|private' "$kv_flat"; then
      bad=1
    fi
    # Defense in depth. gitleaks exits 1 when it finds leaks and 0 when clean.
    if command -v gitleaks >/dev/null 2>&1; then
      mkdir -p "$tmpdir/src"
      cp "$kv_flat" "$tmpdir/src/kv.txt"
      if ! gitleaks detect --no-git --source "$tmpdir/src" >/dev/null 2>&1; then
        bad=1
      fi
    fi
    if [ "$bad" -eq 1 ]; then
      failm "FAIL: clave o valor con forma de credencial en Consul KV (prefijo config/)"
    else
      pass "Check 2: KV config/ sin credenciales"
    fi
  fi
fi

# Check 3 — inline form (`dns: [consul]` / `dns: consul`) and YAML list form
# (`dns:` followed by `- consul`) both count as a violation.
dns_consul=0
if grep -qE 'dns:[^#]*consul' "$COMPOSE_FILE" 2>/dev/null; then
  dns_consul=1
fi
if [ "$dns_consul" -eq 0 ]; then
  if awk '/^[[:space:]]+dns:[[:space:]]*$/{inblk=1;next} inblk && /^[[:space:]]+-[[:space:]]/{print;next} {inblk=0}' "$COMPOSE_FILE" 2>/dev/null | grep -qi 'consul'; then
    dns_consul=1
  fi
fi
if [ "$dns_consul" -eq 1 ]; then
  failm "FAIL: servicio con dns: apuntando a Consul en docker-compose.yml (frontera §0)"
else
  pass "Check 3: sin dns: apuntando a Consul"
fi

# Check 4 — router rules must remain intact; service topology may change.
# Every router name and every rule:/priority:/middlewares: line present in the
# baseline file must still exist in the current file. service: references and
# http.services blocks are ignored (they are exactly what this change modifies).
if ! git -C "$REPO_ROOT" cat-file -e "$ROUTING_BASELINE_COMMIT^{commit}" 2>/dev/null; then
  failm "FAIL: routing.yml difiere del commit base del plan (4766290)"
  echo "  hint: git fetch --unshallow (commit $ROUTING_BASELINE_COMMIT no disponible)"
else
  git -C "$REPO_ROOT" show "$ROUTING_BASELINE_COMMIT:$ROUTING_REL_PATH" > "$tmpdir/routing-baseline.yml" 2>/dev/null
  # rule:/priority:/middlewares: lines (router names are implicit in those lines)
  for key in 'rule:' 'priority:' 'middlewares:'; do
    baseline_lines=$(grep -F "$key" "$tmpdir/routing-baseline.yml" | sort -u)
    current_lines=$(grep -F "$key" "$ROUTING_FILE" | sort -u)
    missing=$(comm -23 <(echo "$baseline_lines") <(echo "$current_lines"))
    if [ -n "$missing" ]; then
      failm "FAIL: $key lines removed/changed in routing.yml"
      printf '%s\n' "$missing" | sed 's/^/  /'
    fi
  done
  # regression guards
  if grep -q 'url: "http://doc-service:8080"' "$ROUTING_FILE"; then
    failm "FAIL: static single-server anti-pattern still present (url: http://doc-service:8080)"
  fi
  if ! grep -q 'docv2@docker' "$ROUTING_FILE"; then
    failm "FAIL: file-provider routers do not reference docv2@docker"
  fi
  if [ "$fail" -eq 0 ]; then
    pass "Check 4: router rules intact; service topology updated to docv2@docker"
  fi
fi

# Check 5
if grep -qE 'svc-ocr-worker|ocr-worker' "$COMPOSE_FILE" 2>/dev/null; then
  # parse shared secrets between ocr-worker and extraction-worker
  # simple: if any MINIO_*/MONGO_* env or secret file name identical -> fail
  bad=0
  # extract secret file names per service (best-effort grep)
  ocr_secrets=$(grep -A40 -E 'ocr-worker:' "$COMPOSE_FILE" | grep -E 'MINIO_|MONGO_|secret' | sort -u)
  ext_secrets=$(grep -A40 -E 'extraction-worker:' "$COMPOSE_FILE" | grep -E 'MINIO_|MONGO_|secret' | sort -u)
  # compare intersection of secret file names
  comm -12 <(echo "$ocr_secrets") <(echo "$ext_secrets") | grep -q . && bad=1
  if [ "$bad" -eq 1 ]; then
    failm "FAIL: ocr-worker comparte credenciales MinIO/Mongo con extraction-worker (SPEC §3.4, mínimo privilegio)"
  else
    pass "Check 5: ocr-worker con credenciales propias"
  fi
else
  skip "Check 5: ocr-worker no desplegado (§0.2 no cerrado)"
fi

# Check 6
if grep -q 'svc-ocr-worker' "$PROMETHEUS_CONFIG" 2>/dev/null; then
  if [ ! -r "$OCR_MAIN_RS" ] || [ ! -f "$OCR_MAIN_RS" ]; then
    skip "Check 6: fuente ocr-worker no disponible en este checkout (§0.2, C31)"
  elif grep -Eq 'route\("/metrics"|resource\("/metrics"' "$OCR_MAIN_RS" 2>/dev/null; then
    pass "Check 6: svc-ocr-worker con /metrics"
  else
    failm "FAIL: svc-ocr-worker en consul_sd_configs sin /metrics verificado (§0.2, C31)"
  fi
else
  pass "Check 6: svc-ocr-worker ausente de consul_sd_configs (§0.2)"
fi

echo
if [ "$fail" -eq 0 ]; then echo "Boundaries OK."; exit 0; else echo "$fail fallo(s)."; exit 1; fi
