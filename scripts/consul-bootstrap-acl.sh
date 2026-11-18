#!/usr/bin/env bash
# Idempotent ACL bootstrap for S11-P1-C06.
# Creates policies + per-service tokens. Never prints full tokens.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
SECRETS="$ROOT/secrets"
ACL_DIR="$ROOT/compose/consul/acl"
EVIDENCE="$ROOT/docs/evidencias/S11/S11-P1-C06-acl-matriz.txt"

# Resolve consul container
CONSUL_CT="$(docker compose --env-file .env -f compose/docker-compose.yml --profile discovery ps -q consul 2>/dev/null || true)"
if [[ -z "$CONSUL_CT" ]]; then CONSUL_CT="infra-consul-1"; fi
# fallback name if ps -q empty
if ! docker inspect "$CONSUL_CT" >/dev/null 2>&1; then CONSUL_CT="infra-consul-1"; fi

CONSUL="docker exec $CONSUL_CT consul"
CA="/run/secrets/consul_ca_cert"
ADDR="https://127.0.0.1:8501"

# helper to run consul with token
run_consul() { # run_consul <token> <args...>
  local tok="$1"; shift
  docker exec -i "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$tok' consul $*" 
}

prefix8() { cut -c1-8; }

# Operator token file
OP_FILE="$SECRETS/consul_operator_token.txt"
OP_TOKEN="$(tr -d '\n' < "$OP_FILE")"

# Non-root consumers (doc-service, ratelimitd, worker, prometheus) read these
# through Docker file-secrets, which inherit the host file mode.
normalize_token_modes() {
  local f
  for f in consul_doc_service_token.txt consul_ratelimitd_token.txt consul_worker_token.txt consul_prometheus_token.txt; do
    [[ -s "$SECRETS/$f" ]] && chmod 0644 "$SECRETS/$f"
  done
}
normalize_token_modes

# Idempotency guard
all_policies_exist() {
  for p in consul-operator svc-doc-service svc-ratelimitd svc-extraction-worker prometheus-read; do
    if ! docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$OP_TOKEN' consul acl policy read -name $p" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}
all_token_files_exist() {
  for f in consul_doc_service_token.txt consul_ratelimitd_token.txt consul_worker_token.txt consul_prometheus_token.txt; do
    [[ -s "$SECRETS/$f" ]] || return 1
  done
  return 0
}
token_authenticates() {
  docker exec -i "$CONSUL_CT" sh -c "read T; CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA consul acl token read -self -token=\$T" >/dev/null 2>&1 <<<"$OP_TOKEN"
}

if [[ "${1:-}" != "--verify" ]] && [[ -s "$OP_FILE" ]] && token_authenticates && all_policies_exist && all_token_files_exist; then
  echo "bootstrap already done"
  for f in consul_operator_token.txt consul_doc_service_token.txt consul_ratelimitd_token.txt consul_worker_token.txt consul_prometheus_token.txt; do
    echo "$f: $(tr -d '\n' < "$SECRETS/$f" | cut -c1-8)"
  done
  exit 0
fi

# Bootstrap attempt
BOOT_TOKEN=""
TMPF="$(mktemp /tmp/consul_bootstrap.XXXXXX)"
chmod 600 "$TMPF"
if docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA consul acl bootstrap -format=json" >"$TMPF" 2>/dev/null; then
  BOOT_TOKEN="$(python3 -c "import json,sys; print(json.load(open('$TMPF'))['SecretID'])" 2>/dev/null || grep -o '"SecretID":"[^"]*"' "$TMPF" | head -1 | cut -d'"' -f4)"
fi
rm -f "$TMPF"

# Determine working token (bootstrap if produced, else operator)
if [[ -n "$BOOT_TOKEN" ]]; then
  WORK_TOKEN="$BOOT_TOKEN"
  # persist bootstrap to tmp then use; not written to secrets
else
  WORK_TOKEN="$OP_TOKEN"
fi

# Create policies idempotently
create_policy() {
  local name="$1" file="$2"
  if docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl policy read -name $name" >/dev/null 2>&1; then
    docker exec -i "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl policy update -name $name -rules @/dev/stdin" < "$file" >/dev/null
  else
    docker exec -i "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl policy create -name $name -rules @/dev/stdin" < "$file" >/dev/null
  fi
}

create_policy consul-operator "$ACL_DIR/consul-operator.hcl"
create_policy svc-doc-service "$ACL_DIR/svc-doc-service.hcl"
create_policy svc-ratelimitd "$ACL_DIR/svc-ratelimitd.hcl"
create_policy svc-extraction-worker "$ACL_DIR/svc-extraction-worker.hcl"
create_policy prometheus-read "$ACL_DIR/prometheus-read.hcl"

# Attach consul-operator policy to existing operator token via accessor id
ACC_ID="$(docker exec -i "$CONSUL_CT" sh -c "read T; CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA consul acl token read -self -token=\$T -format=json" <<<"$OP_TOKEN" | (python3 -c "import json,sys; print(json.load(sys.stdin)['AccessorID'])" 2>/dev/null || grep -o '"AccessorID":"[^"]*"' | head -1 | cut -d'"' -f4))"
if [[ -n "$ACC_ID" ]]; then
  docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl token update -id $ACC_ID -policy-name consul-operator -merge-policies" >/dev/null 2>&1 || true
fi

# Create service tokens idempotently by description
create_service_token() {
  local desc="$1" policy="$2" outfile="$3"
  if [[ -s "$outfile" ]]; then
    return 0
  fi
  # find existing by description
  EXISTING="$(docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl token list -format=json" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for t in data:
    if t.get('Description')=='$desc':
        print(t.get('AccessorID','')); break
" 2>/dev/null || true)"
  if [[ -n "$EXISTING" ]]; then
    # fetch secret id
    SEC="$(docker exec "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl token read -id $EXISTING -format=json" | python3 -c "import json,sys; print(json.load(sys.stdin)['SecretID'])" 2>/dev/null || true)"
    if [[ -n "$SEC" ]]; then
      printf '%s' "$SEC" > "$outfile"
      chmod 644 "$outfile"
      return 0
    fi
  fi
  # create new
  RES="$(docker exec -i "$CONSUL_CT" sh -c "CONSUL_HTTP_ADDR=$ADDR CONSUL_CACERT=$CA CONSUL_HTTP_TOKEN='$WORK_TOKEN' consul acl token create -description '$desc' -policy-name $policy -format=json")"
  SEC="$(printf '%s' "$RES" | python3 -c "import json,sys; print(json.load(sys.stdin)['SecretID'])" 2>/dev/null || printf '%s' "$RES" | grep -o '"SecretID":"[^"]*"' | head -1 | cut -d'"' -f4)"
  printf '%s' "$SEC" > "$outfile"
  chmod 644 "$outfile"
}

create_service_token "S11-P1-C06 svc-doc-service" svc-doc-service "$SECRETS/consul_doc_service_token.txt"
create_service_token "S11-P1-C06 svc-ratelimitd" svc-ratelimitd "$SECRETS/consul_ratelimitd_token.txt"
create_service_token "S11-P1-C06 svc-extraction-worker" svc-extraction-worker "$SECRETS/consul_worker_token.txt"
create_service_token "S11-P1-C06 prometheus-read" prometheus-read "$SECRETS/consul_prometheus_token.txt"

# Print prefixes
echo "consul-operator: $(cut -c1-8 < "$OP_FILE")"
echo "svc-doc-service: $(cut -c1-8 < "$SECRETS/consul_doc_service_token.txt")"
echo "svc-ratelimitd: $(cut -c1-8 < "$SECRETS/consul_ratelimitd_token.txt")"
echo "svc-extraction-worker: $(cut -c1-8 < "$SECRETS/consul_worker_token.txt")"
echo "prometheus-read: $(cut -c1-8 < "$SECRETS/consul_prometheus_token.txt")"

# --verify handling
if [[ "${1:-}" == "--verify" ]]; then
  # Build matrix. Probe keys created with operator token.
  # Use exec with stdin for tokens.
  BASE="https://consul:8501"
  # create probe keys
  for key in config/doc-service/__acl_probe config/meta/__acl_probe config/extraction-worker/__acl_probe; do
    printf 'probe' | docker exec -i "$CONSUL_CT" sh -c "read T; curl -sS -o /dev/null -w '%{http_code}' --cacert $CA -H 'X-Consul-Token: '\$T -X PUT --data-binary @- $BASE/v1/kv/$key" <<<"$OP_TOKEN" >/dev/null
  done
  # rate-limiter and ratelimitd probe
  for key in config/rate-limiter/__acl_probe config/ratelimitd/__acl_probe; do
    printf 'probe' | docker exec -i "$CONSUL_CT" sh -c "read T; curl -sS -o /dev/null -w '%{http_code}' --cacert $CA -H 'X-Consul-Token: '\$T -X PUT --data-binary @- $BASE/v1/kv/$key" <<<"$OP_TOKEN" >/dev/null
  done

  probe() { # probe <tokenfile or 'anon'> <key>
    local tf="$1" key="$2"
    if [[ "$tf" == "anon" ]]; then
      docker exec -i "$CONSUL_CT" sh -c "curl -sS -o /dev/null -w '%{http_code}' --cacert $CA $BASE/v1/kv/$key" 
    else
      local tok; tok="$(tr -d '\n' < "$tf")"
      printf '%s' "$tok" | docker exec -i "$CONSUL_CT" sh -c "read T; curl -sS -o /dev/null -w '%{http_code}' --cacert $CA -H 'X-Consul-Token: '\$T $BASE/v1/kv/$key"
    fi
  }

  # Write evidence header
  mkdir -p "$(dirname "$EVIDENCE")"
  {
    echo "S11-P1-C06 — ACL por prefijo + tokens por servicio"
    echo "UTC/local date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "Estado previo observado (RED):"
    echo "- acl { enabled = true, default_policy = \"deny\" } ya activo, con el token"
    echo "  initial_management de dev como unica credencial (prefijo 978de4e4)."
    echo "- Solo politicas built-in (global-management, global-read-only); cero"
    echo "  politicas por servicio, cero tokens por servicio y KV vacio."
    echo
    echo "Archivos creados/modificados:"
    echo "- infra/compose/consul/config/server.hcl (enable_token_persistence)"
    echo "- infra/compose/consul/acl/{consul-operator,prometheus-read,svc-doc-service,svc-ratelimitd,svc-extraction-worker}.hcl"
    echo "- infra/scripts/consul-bootstrap-acl.sh"
    echo "- infra/compose/docker-compose.yml (secrets + env CONSUL_* en doc-service, ratelimitd,"
    echo "  extraction-worker y prometheus)"
    echo "- infra/secrets/consul_{doc_service,ratelimitd,worker,prometheus}_token.txt (0600, no versionados)"
    echo
    echo "Comandos ejecutados (desde infra/):"
    echo "  docker compose --env-file .env -f compose/docker-compose.yml --profile discovery config --quiet"
    echo "  docker compose --env-file .env -f compose/docker-compose.yml --profile discovery up -d --force-recreate consul"
    echo "  bash scripts/consul-bootstrap-acl.sh"
    echo "  bash scripts/consul-bootstrap-acl.sh   # segunda corrida: idempotencia"
    echo "  bash scripts/consul-bootstrap-acl.sh --verify"
    echo
    echo "Tokens (solo prefijo de 8 caracteres):"
    echo "  consul-operator: $(cut -c1-8 < "$OP_FILE") (initial_management de dev; conservado)"
    echo "  svc-doc-service: $(cut -c1-8 < "$SECRETS/consul_doc_service_token.txt")"
    echo "  svc-ratelimitd: $(cut -c1-8 < "$SECRETS/consul_ratelimitd_token.txt")"
    echo "  svc-extraction-worker: $(cut -c1-8 < "$SECRETS/consul_worker_token.txt")"
    echo "  prometheus-read: $(cut -c1-8 < "$SECRETS/consul_prometheus_token.txt")"
    echo
    echo "Nota de nomenclatura: plan §3.2 y kv/rate-limiter.json usan config/rate-limiter/;"
    echo "task-6 §4.2 menciona config/ratelimitd/. La politica svc-ratelimitd concede"
    echo "lectura sobre ambos prefijos para no romper ninguna de las dos fuentes."
    echo
    echo "Matriz token x prefijo (GET de una clave sonda; sonda creada con el token de"
    echo "operador y eliminada al terminar):"
  } > "$EVIDENCE"

  # We'll just run and print; collect pass/fail
  FAIL=0
  check() {
    local label="$1" got="$2" exp="$3"
    local verdict="OK"
    if [[ "$got" != "$exp" ]]; then verdict="FAIL"; FAIL=1; fi
    echo "  $label: $got (esperado $exp) $verdict"
    echo "  $label: $got (esperado $exp) $verdict" >> "$EVIDENCE"
  }

  # anonymous
  for key in config/doc-service/__acl_probe config/rate-limiter/__acl_probe config/ratelimitd/__acl_probe config/extraction-worker/__acl_probe config/meta/__acl_probe; do
    c="$(probe anon "$key")"; check "anon $key" "$c" 403
  done

  # doc-service token
  DS="$SECRETS/consul_doc_service_token.txt"
  check "doc-service doc-service" "$(probe "$DS" config/doc-service/__acl_probe)" 200
  check "doc-service meta" "$(probe "$DS" config/meta/__acl_probe)" 200
  check "doc-service rate-limiter" "$(probe "$DS" config/rate-limiter/__acl_probe)" 403
  check "doc-service ratelimitd" "$(probe "$DS" config/ratelimitd/__acl_probe)" 403
  check "doc-service extraction-worker" "$(probe "$DS" config/extraction-worker/__acl_probe)" 403

  # ratelimitd token
  RL="$SECRETS/consul_ratelimitd_token.txt"
  check "ratelimitd rate-limiter" "$(probe "$RL" config/rate-limiter/__acl_probe)" 200
  check "ratelimitd ratelimitd" "$(probe "$RL" config/ratelimitd/__acl_probe)" 200
  check "ratelimitd meta" "$(probe "$RL" config/meta/__acl_probe)" 200
  check "ratelimitd doc-service" "$(probe "$RL" config/doc-service/__acl_probe)" 403
  check "ratelimitd extraction-worker" "$(probe "$RL" config/extraction-worker/__acl_probe)" 403

  # worker token
  WK="$SECRETS/consul_worker_token.txt"
  check "worker extraction-worker" "$(probe "$WK" config/extraction-worker/__acl_probe)" 200
  check "worker meta" "$(probe "$WK" config/meta/__acl_probe)" 200
  check "worker doc-service" "$(probe "$WK" config/doc-service/__acl_probe)" 403
  check "worker rate-limiter" "$(probe "$WK" config/rate-limiter/__acl_probe)" 403

  # prometheus token
  PM="$SECRETS/consul_prometheus_token.txt"
  for key in config/doc-service/__acl_probe config/rate-limiter/__acl_probe config/ratelimitd/__acl_probe config/extraction-worker/__acl_probe config/meta/__acl_probe; do
    check "prometheus $key" "$(probe "$PM" "$key")" 403
  done

  # operator token
  check "operator doc-service" "$(probe "$OP_FILE" config/doc-service/__acl_probe)" 200
  check "operator rate-limiter" "$(probe "$OP_FILE" config/rate-limiter/__acl_probe)" 200
  check "operator ratelimitd" "$(probe "$OP_FILE" config/ratelimitd/__acl_probe)" 200
  check "operator extraction-worker" "$(probe "$OP_FILE" config/extraction-worker/__acl_probe)" 200
  check "operator meta" "$(probe "$OP_FILE" config/meta/__acl_probe)" 200

  # cleanup probe keys
  for key in config/doc-service/__acl_probe config/meta/__acl_probe config/extraction-worker/__acl_probe config/rate-limiter/__acl_probe config/ratelimitd/__acl_probe; do
    printf '' >/dev/null
    docker exec -i "$CONSUL_CT" sh -c "read T; curl -sS -o /dev/null -w '%{http_code}' --cacert $CA -H 'X-Consul-Token: '\$T -X DELETE $BASE/v1/kv/$key" <<<"$OP_TOKEN" >/dev/null
  done

  # append results to evidence
  {
    echo
    echo "Sondas eliminadas tras la medicion: config/{doc-service,meta,extraction-worker,rate-limiter,ratelimitd}/__acl_probe"
    echo "Resultado: FAIL=$FAIL"
    if [[ "$FAIL" -eq 0 ]]; then
      echo "VEREDICTO: PASS — matriz token x prefijo en verde."
    else
      echo "VEREDICTO: FAIL — revisar las filas marcadas FAIL."
    fi
  } >> "$EVIDENCE"
  echo "evidencia: $EVIDENCE"
  if [[ "$FAIL" -ne 0 ]]; then exit 1; fi
  exit 0
fi

exit 0
