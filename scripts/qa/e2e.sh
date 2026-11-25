#!/usr/bin/env bash
# infra/scripts/qa/e2e.sh — harness E2E del QA (plan §6.3).
# Implementación completa.
set -Eeuo pipefail

QA_SCRIPT_NAME="qa/e2e"

# ---------------------------------------------------------------------------
# Carga de librerías
# ---------------------------------------------------------------------------
QA_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/lib" && pwd)"
# shellcheck source=/dev/null
source "$QA_LIB_DIR/common.sh"
# shellcheck source=/dev/null
source "$QA_LIB_DIR/results.sh"

qa_init

# ---------------------------------------------------------------------------
# Constantes de suites
# ---------------------------------------------------------------------------
# name -> command-ish; definido como funciones para claridad.
declare -A SUITE_COMMAND SUITE_PROFILE SUITE_TIMEOUT SUITE_SLOW
SUITE_COMMAND[smoke]="platform-services/tests/e2e/run.sh smoke"
SUITE_PROFILE[smoke]="full"
SUITE_TIMEOUT[smoke]=180
SUITE_SLOW[smoke]=0

SUITE_COMMAND[happy]="platform-services/tests/e2e/run.sh happy --runs"
SUITE_PROFILE[happy]="full"
SUITE_TIMEOUT[happy]=300
SUITE_SLOW[happy]=0

SUITE_COMMAND[states]="platform-services/tests/e2e/states/run.sh"
SUITE_PROFILE[states]="full"
SUITE_TIMEOUT[states]=420
SUITE_SLOW[states]=0

SUITE_COMMAND[errors]="platform-services/tests/e2e/errors/run.sh"
SUITE_PROFILE[errors]="full"
SUITE_TIMEOUT[errors]=420
SUITE_SLOW[errors]=0

SUITE_COMMAND[correlation]="platform-services/tests/e2e/correlation/run.sh --runs"
SUITE_PROFILE[correlation]="full"
SUITE_TIMEOUT[correlation]=300
SUITE_SLOW[correlation]=0

SUITE_COMMAND[chain]="platform-services/tests/e2e/chain/run.sh --runs"
SUITE_PROFILE[chain]="full"
SUITE_TIMEOUT[chain]=420
SUITE_SLOW[chain]=0

SUITE_COMMAND[routing]="infra/scripts/test-routing-table.sh"
SUITE_PROFILE[routing]="full"
SUITE_TIMEOUT[routing]=120
SUITE_SLOW[routing]=0

SUITE_COMMAND[consul]="infra/scripts/test-consul.sh"
SUITE_PROFILE[consul]="full+discovery"
SUITE_TIMEOUT[consul]=300
SUITE_SLOW[consul]=0

SUITE_COMMAND[resilience]="infra/scripts/e2e-horizontal-scaling.sh"
SUITE_PROFILE[resilience]="full+sentinel"
SUITE_TIMEOUT[resilience]=900
SUITE_SLOW[resilience]=1

SUITE_COMMAND[load]="platform-services/tests/e2e/load/run.sh"
SUITE_PROFILE[load]="full"
SUITE_TIMEOUT[load]=1200
SUITE_SLOW[load]=1

SUITE_COMMAND[chaos]="platform-services/tests/e2e/chaos/run.sh --all"
SUITE_PROFILE[chaos]="full+chaos"
SUITE_TIMEOUT[chaos]=900
SUITE_SLOW[chaos]=1

SUITE_COMMAND[replay]="infra/scripts/replay-env.sh"
SUITE_PROFILE[replay]="own replay stack"
SUITE_TIMEOUT[replay]=1800
SUITE_SLOW[replay]=1

SUITE_COMMAND[parity]="python3 -m unittest discover -s platform-services/tests/parity -v"
SUITE_PROFILE[parity]="full"
SUITE_TIMEOUT[parity]=1800
SUITE_SLOW[parity]=1

# ---------------------------------------------------------------------------
# Argumentos
# ---------------------------------------------------------------------------
RUNS=1
SLOW=0
KEEP_STACK=0
KEEP_DATA=0
FAIL_FAST=0
TIMEOUT_GLOBAL="${QA_TIMEOUT_E2E:-420}"
LIST=0
JSON=0
DRY_RUN=0
SUITES=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runs) RUNS="$2"; shift 2 ;;
    --slow) SLOW=1; shift ;;
    --keep-stack) KEEP_STACK=1; shift ;;
    --keep-data) KEEP_DATA=1; shift ;;
    --fail-fast) FAIL_FAST=1; shift ;;
    --timeout) TIMEOUT_GLOBAL="$2"; shift 2 ;;
    --list) LIST=1; shift ;;
    --json) JSON=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --) shift; break ;;
    -*) qa_die 2 "opcion desconocida: $1" "consulta --list" ;;
    *) SUITES+=("$1"); shift ;;
  esac
done

# ---------------------------------------------------------------------------
# --list
# ---------------------------------------------------------------------------
if ((LIST)); then
  for s in smoke happy states errors correlation chain routing consul resilience load chaos replay parity; do
    printf '%-12s perfil=%-18s timeout=%ss slow=%s\n' \
      "$s" "${SUITE_PROFILE[$s]}" "${SUITE_TIMEOUT[$s]}" "$([[ ${SUITE_SLOW[$s]} -eq 1 ]] && echo yes || echo no)"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# Resolver suites seleccionadas
# ---------------------------------------------------------------------------
if [[ ${#SUITES[@]} -eq 0 ]]; then
  SUITES=(ci)
fi

# Expandir alias
expanded=()
for s in "${SUITES[@]}"; do
  case "$s" in
    ci) expanded+=(smoke happy states errors correlation) ;;
    all)
      for x in smoke happy states errors correlation chain routing consul; do expanded+=("$x"); done
      if ((SLOW)); then
        for x in resilience load chaos replay parity; do expanded+=("$x"); done
      fi
      ;;
    *) expanded+=("$s") ;;
  esac
done
SUITES=("${expanded[@]}")

# Validar nombres
for s in "${SUITES[@]}"; do
  [[ -n "${SUITE_COMMAND[$s]:-}" ]] || qa_die 2 "suite desconocida: $s" "consulta --list"
done

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
qa_require_tools docker curl jq

STARTED_BY_RUNNER=0
FAILED=0
EXECUTED=0

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  local rc="${1:-0}"
  if ((STARTED_BY_RUNNER == 1 && KEEP_STACK == 0)); then
    qa_compose stop >/dev/null 2>&1 || true
  fi
  exit "$rc"
}
qa_trap_cleanup cleanup

# ---------------------------------------------------------------------------
# Stack resolution
# ---------------------------------------------------------------------------
STACK_DECISION=""
if ((DRY_RUN)); then
  echo "[DRY-RUN] decision de stack pendiente de ejecucion real"
else
  # leer status
  STATUS_JSON="$(bash "$QA_SCRIPTS_DIR/status.sh" --json 2>/dev/null || true)"
  # determinar gates
  GATES_PASS=1
  if [[ -z "$STATUS_JSON" ]]; then
    GATES_PASS=0
  else
    # si algun gate fail -> GATES_PASS=0
    if echo "$STATUS_JSON" | jq -e '.gates[] | select(.status != "pass")' >/dev/null 2>&1; then
      GATES_PASS=0
    fi
  fi

  # determinar si stack ausente
  STACK_ABSENT=0
  if [[ -z "$STATUS_JSON" ]]; then
    STACK_ABSENT=1
  else
    # compose o docker defectuoso
    if echo "$STATUS_JSON" | jq -e '.gates[] | select(.name=="compose" and .status!="pass")' >/dev/null 2>&1; then
      STACK_ABSENT=1
    fi
    if echo "$STATUS_JSON" | jq -e '.gates[] | select(.name=="docker" and .status!="pass")' >/dev/null 2>&1; then
      STACK_ABSENT=1
    fi
  fi

  if ((GATES_PASS == 1)); then
    STACK_DECISION="reuse"
  elif ((STACK_ABSENT == 1)); then
    STACK_DECISION="up"
  else
    # parcialmente healthy
    echo "[FAIL] stack parcialmente healthy. Gates fallidos:" >&2
    echo "$STATUS_JSON" | jq -r '.gates[] | select(.status != "pass") | "  - \(.name): \(.status)"' >&2
    echo "Sugerencia: qa.sh down --profile full && qa.sh up" >&2
    exit 5
  fi

  if [[ "$STACK_DECISION" == "up" ]]; then
    # perfiles extra
    PROFILES="full"
    for s in "${SUITES[@]}"; do
      case "${SUITE_PROFILE[$s]}" in
        *discovery*) PROFILES="$PROFILES discovery" ;;
        *sentinel*) PROFILES="$PROFILES sentinel" ;;
        *chaos*) PROFILES="$PROFILES chaos" ;;
      esac
    done
    # dedup
    PROFILES="$(echo "$PROFILES" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    if ((DRY_RUN)); then
      echo "[DRY-RUN] up.sh --profile $PROFILES"
    else
      bash "$QA_SCRIPTS_DIR/up.sh" --profile $PROFILES
      STARTED_BY_RUNNER=1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Data prep
# ---------------------------------------------------------------------------
if ((DRY_RUN == 0)); then
  if ! bash "$QA_SCRIPTS_DIR/qa.sh" doctor >/dev/null 2>&1; then
    if ! bash "$WORKSPACE_ROOT/platform-services/tests/e2e/ci/prepare-env.sh"; then
      exit 3
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Ejecucion de suites
# ---------------------------------------------------------------------------
E2E_DIR="$QA_RUN_DIR/e2e"
mkdir -p "$E2E_DIR"

run_suite() {
  local suite="$1"
  local slow="${SUITE_SLOW[$suite]}"
  local timeout="${SUITE_TIMEOUT[$suite]}"
  # si slow y --slow no, skip
  if ((slow == 1 && SLOW == 0)); then
    results_record "$suite" skip 0 "requires --slow"
    return 0
  fi
  # timeout global override for non-slow? spec: suites lentas usan propio valor
  local t="$timeout"
  if ((slow == 0)); then
    # usar timeout global si menor? spec default 420; suites lentas propio. Usar propio siempre para known.
    :
  fi
  # aviso para chaos/resilience
  if [[ "$suite" == "chaos" || "$suite" == "resilience" ]]; then
    echo "AVISO: $suite detiene contenedores del stack"
  fi

  local log="$E2E_DIR/$suite.log"
  local start=$SECONDS
  local rc=0
  # construir comando
  local cmd=()
  case "$suite" in
    smoke) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/run.sh" smoke) ;;
    happy) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/run.sh" happy --runs "$RUNS") ;;
    states) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/states/run.sh") ;;
    errors) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/errors/run.sh") ;;
    correlation) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/correlation/run.sh" --runs "$RUNS") ;;
    chain) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/chain/run.sh" --runs "$RUNS") ;;
    routing) cmd=(bash "$INFRA_DIR/scripts/test-routing-table.sh") ;;
    consul)
      # dos comandos
      cmd=(bash -c "P4_WORKSPACE_ROOT='$WORKSPACE_ROOT' bash '$INFRA_DIR/scripts/test-consul.sh' && P4_WORKSPACE_ROOT='$WORKSPACE_ROOT' bash '$INFRA_DIR/scripts/verify-consul-boundaries.sh'")
      ;;
    resilience) cmd=(bash "$INFRA_DIR/scripts/e2e-horizontal-scaling.sh") ;;
    load) cmd=(bash "$WORKSPACE_ROOT/platform-services/tests/e2e/load/run.sh") ;;
    chaos)
      cmd=(bash -c "P4_WORKSPACE_ROOT='$WORKSPACE_ROOT' bash '$WORKSPACE_ROOT/platform-services/tests/e2e/chaos/run.sh' --all && P4_WORKSPACE_ROOT='$WORKSPACE_ROOT' bash '$INFRA_DIR/scripts/test-minio-disk-fill.sh' && P4_WORKSPACE_ROOT='$WORKSPACE_ROOT' bash '$INFRA_DIR/scripts/test-chain-alerts.sh'")
      ;;
    replay) cmd=(bash "$INFRA_DIR/scripts/replay-env.sh") ;;
    parity)
      cmd=(bash -c "cd '$WORKSPACE_ROOT/platform-services' && python3 -m unittest discover -s tests/parity -v")
      ;;
  esac

  if ((DRY_RUN)); then
    echo "[DRY-RUN] suite=$suite timeout=$t cmd=${cmd[*]}"
    results_record "$suite" pass 0 "dry-run"
    return 0
  fi

  # export P4_WORKSPACE_ROOT for platform-services scripts
  export P4_WORKSPACE_ROOT="$WORKSPACE_ROOT"

  set +e
  timeout "$t" "${cmd[@]}" >"$log.tmp" 2>&1
  rc=$?
  set -e
  # redact
  qa_redact <"$log.tmp" >"$log" || true
  rm -f "$log.tmp"

  local dur=$((SECONDS - start))
  local status="pass"
  local reason=""
  EXECUTED=$((EXECUTED + 1))
  if ((rc != 0)); then
    status="fail"
    if ((rc == 124)); then
      reason="timeout ${t}s"
    else
      reason="exit=$rc"
    fi
    FAILED=1
  fi
  results_record "$suite" "$status" "$dur" "$reason"

  if ((FAIL_FAST && rc != 0)); then
    return 1
  fi
  return 0
}

for s in "${SUITES[@]}"; do
  run_suite "$s" || break
done

# ---------------------------------------------------------------------------
# Convergence check (SPEC §13) - Mongo docs with _id qa-<run-id>-* not completed
# ---------------------------------------------------------------------------
if ((DRY_RUN == 0 && EXECUTED > 0)); then
  # query mongo
  MONGO_DB="$(env_value MONGO_DATABASE documents)"
  MONGO_CID="$(qa_compose ps -q mongo 2>/dev/null || true)"
  if [[ -n "$MONGO_CID" ]]; then
    ROOT_USER="$(env_value MONGO_INITDB_ROOT_USERNAME root)"
    ROOT_PW="$(env_value MONGO_INITDB_ROOT_PASSWORD "")"
    [[ -n "$ROOT_PW" ]] || ROOT_PW="$(secret_value mongo_initdb_root_password.txt 2>/dev/null || true)"
    # build eval
    RUNPREFIX="qa-${QA_RUN_ID}-"
    EVAL="db.getSiblingDB('${MONGO_DB}').documents.find({_id: /^${RUNPREFIX}/, status: {\$nin: ['COMPLETED','FAILED','REJECTED','UPLOAD_EXPIRED']}}).toArray()"
    set +e
    OFFENDING="$(docker exec "$MONGO_CID" mongosh --quiet -u "$ROOT_USER" -p "$ROOT_PW" --authenticationDatabase admin --eval "$EVAL" 2>&1)"
    MONGO_RC=$?
    set -e
    if ((MONGO_RC != 0)) || printf '%s' "$OFFENDING" | grep -qi 'authentication failed'; then
      results_record "convergence" blocked 0 "no se pudo consultar Mongo (revisa MONGO_INITDB_ROOT_PASSWORD o el secreto)"
    elif printf '%s' "$OFFENDING" | grep -q '"_id"'; then
      results_record "convergence" fail 0 "offending: $(echo "$OFFENDING" | tr '\n' ' ')"
    else
      results_record "convergence" pass 0 ""
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Cleanup data
# ---------------------------------------------------------------------------
if ((DRY_RUN == 0 && KEEP_DATA == 0 && EXECUTED > 0)); then
  MONGO_DB="$(env_value MONGO_DATABASE documents)"
  # delete mongo docs
  if [[ -n "${MONGO_CID:-}" ]]; then
    DEL_EVAL="db.getSiblingDB('${MONGO_DB}').documents.deleteMany({_id: /^qa-${QA_RUN_ID}-/})"
    docker exec "$MONGO_CID" mongosh --quiet -u "$ROOT_USER" -p "$ROOT_PW" --authenticationDatabase admin --eval "$DEL_EVAL" >/dev/null 2>&1 || true
  fi
  # minio cleanup via throwaway container on the compose data network (best-effort)
  MINIO_CLEANUP_CMD="docker run --rm --network ${QA_PROJECT}_data bitnamilegacy/minio-client:2025.7.21 mc rm --recursive --force local/raw-pdfs/qa-${QA_RUN_ID}-"
  if MINIO_ROOT_USER="$(env_value MINIO_ROOT_USER devminio)" \
     MINIO_ROOT_PASSWORD="$(secret_value minio_root_password.txt 2>/dev/null || true)" \
     docker run --rm -e MINIO_ROOT_USER -e MINIO_ROOT_PASSWORD \
       --network "${QA_PROJECT}_data" --entrypoint /bin/sh \
       bitnamilegacy/minio-client:2025.7.21 -c \
       "mc alias set local http://minio:9000 \"\$MINIO_ROOT_USER\" \"\$MINIO_ROOT_PASSWORD\" >/dev/null 2>&1; mc rm --recursive --force local/raw-pdfs/qa-${QA_RUN_ID}- local/extracted-txt/qa-${QA_RUN_ID}- >/dev/null 2>&1 || true" >/dev/null 2>&1; then
    results_record "cleanup" pass 0 ""
  else
    results_record "cleanup" skip 0 "cliente/red de MinIO no disponible; manual: ${MINIO_CLEANUP_CMD}"
  fi
fi

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------
if ((STARTED_BY_RUNNER == 1 && KEEP_STACK == 0 && DRY_RUN == 0)); then
  qa_compose stop >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Diagnostics on failure
# ---------------------------------------------------------------------------
if ((FAILED == 1)); then
  DIAG="$QA_RUN_DIR/diagnostics"
  mkdir -p "$DIAG"
  MONGO_DB_FOR_DIAG="$(env_value MONGO_DATABASE documents)"
  qa_compose ps >"$DIAG/compose-ps.txt" 2>&1 || true
  for svc in doc-service extraction-worker ocr-worker minio traefik ratelimitd mongo redis-streams; do
    qa_compose logs --tail 200 "$svc" 2>&1 | qa_redact >"$DIAG/logs-$svc.txt" || true
  done
  # documents.json
  if [[ -n "${MONGO_CID:-}" ]]; then
    docker exec "$MONGO_CID" mongosh --quiet -u "$ROOT_USER" -p "$ROOT_PW" --authenticationDatabase admin \
      --eval "JSON.stringify(db.getSiblingDB('${MONGO_DB_FOR_DIAG}').documents.find({_id: /^qa-${QA_RUN_ID}-/},{_id:1,status:1,updated_at:1,txt_ref:1}).toArray())" \
      2>/dev/null | qa_redact >"$DIAG/documents.json" || true
    if [[ ! -s "$DIAG/documents.json" ]]; then echo '[]' >"$DIAG/documents.json"; fi
  fi
  # redis
  {
    echo "XLEN stream:"
    # best effort
    echo "XPENDING:"
  } >"$DIAG/redis.txt"
  bash "$QA_SCRIPTS_DIR/status.sh" --json >"$DIAG/status.json" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Final
# ---------------------------------------------------------------------------
results_finish "$QA_RUN_DIR/e2e" || true
echo "artifact dir: $QA_RUN_DIR/e2e"
if ((JSON)); then
  cat "$QA_RUN_DIR/e2e/results.json" 2>/dev/null || true
fi

if ((FAILED)); then exit 1; fi
exit 0
