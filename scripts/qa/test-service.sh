#!/usr/bin/env bash
# test-service.sh — ejecuta la matriz de tests QA por destino (plan §5.4).
set -Eeuo pipefail

QA_SCRIPT_NAME="qa/test"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/deps.sh"
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/results.sh"

# ---------------- args ----------------
DEST=""
SELECTORS=()
NO_DEPS=0
KEEP_DEPS=0
TIMEOUT_OVERRIDE=""
JSON=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    doc-service|extraction-worker|ocr-worker|platform-services|infra|all) DEST="$1"; shift ;;
    --unit) SELECTORS+=("unit"); shift ;;
    --integration) SELECTORS+=("integration"); shift ;;
    --lint) SELECTORS+=("lint"); shift ;;
    --all) SELECTORS+=("lint" "unit" "integration"); shift ;;
    --no-deps) NO_DEPS=1; shift ;;
    --keep-deps) KEEP_DEPS=1; shift ;;
    --timeout) TIMEOUT_OVERRIDE="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    -h|--help)
      cat <<'EOF'
Uso: qa.sh test <destino> [opciones]
  destino: doc-service | extraction-worker | ocr-worker | platform-services | infra | all
  --unit            solo unitarios/herméticos
  --integration     solo integración (levanta dependencias efímeras)
  --lint            solo lint
  --all             lint + unit + integration (default cuando no se pasa selector)
  --no-deps         no levanta dependencias efímeras
  --keep-deps       no destruye el stack efímero al terminar
  --timeout <s>     override del timeout de la etapa
  --json            imprime results.json al final
  -h|--help
EOF
      exit 0 ;;
    *) qa_die 2 "opción desconocida: $1" "qa.sh test <destino> [opciones]" ;;
  esac
done

[[ -n "$DEST" ]] || qa_die 2 "falta destino" "qa.sh test <destino> [opciones]"

if [[ ${#SELECTORS[@]} -eq 0 ]]; then SELECTORS=("lint" "unit" "integration"); fi

# dedup while preserving order
declare -a UNIQUE=()
for s in "${SELECTORS[@]}"; do
  skip=0
  for u in "${UNIQUE[@]:-}"; do [[ "$u" == "$s" ]] && skip=1; done
  [[ $skip -eq 0 ]] && UNIQUE+=("$s")
done
SELECTORS=("${UNIQUE[@]}")

qa_init
results_init "test/$DEST"
mkdir -p "$QA_RUN_DIR/test-$DEST"
chmod 700 "$QA_RUN_DIR/test-$DEST"
ARTDIR="$QA_RUN_DIR/test-$DEST"

# ---------------- helpers ----------------
run_check() {
  # run_check <dest> <stage> <short> <timeout> <log> <cmd...>
  local dest="$1" stage="$2" short="$3" tout="$4" log="$5"
  shift 5
  local start end dur rc=0
  start=$(date +%s)
  # shellcheck disable=SC2094
  if timeout "$tout" "$@" >"$log.tmp" 2>&1; then
    rc=0
  else
    rc=$?
  fi
  # redact + truncate
  qa_redact <"$log.tmp" >"$log" 2>/dev/null || true
  rm -f "$log.tmp"
  qa_truncate_file "$log" 5242880
  end=$(date +%s)
  dur=$((end-start))
  local status
  if [[ $rc -eq 124 ]]; then status="fail"; local reason="timeout ${tout}s"
  elif [[ $rc -eq 0 ]]; then status="pass"; reason=""
  else status="fail"; reason="exit $rc"
  fi
  results_record "$dest · $stage · $short" "$status" "$dur" "$reason"
  # store for failure output
  _LAST_RC=$rc
  _LAST_LOG="$log"
  _LAST_CMD="$*"
  _LAST_REASON="$reason"
  _LAST_SHORT="$short"
  _LAST_STAGE="$stage"
  _LAST_DEST="$dest"
  if [[ $rc -ne 0 ]]; then
    print_failure
  fi
  return 0
}

print_failure() {
  echo "[FAIL] $_LAST_DEST · $_LAST_STAGE · $_LAST_SHORT" >&2
  echo "       comando: $_LAST_CMD" >&2
  echo "       causa:  $_LAST_REASON" >&2
  echo "       ver:    $_LAST_LOG" >&2
  echo "       accion: revisa el log indicado" >&2
  echo "---- ultimas 40 lineas (redactadas) ----" >&2
  tail -n 40 "$_LAST_LOG" 2>/dev/null | sed 's/^/       /' >&2
}

run_wrap() {
  # run_wrap <dir> <cmd...>
  local dir="$1"; shift
  ( cd "$dir" && "$@" )
}

# ---------------- preflight tools ----------------
case "$DEST" in
  doc-service)
    qa_require_tools go gcc
    ;;
  extraction-worker|ocr-worker)
    qa_require_tools cargo
    ;;
  platform-services)
    qa_require_tools make go
    ;;
  infra)
    qa_require_tools bash
    if command -v shellcheck >/dev/null 2>&1; then :; fi
    if command -v yamllint >/dev/null 2>&1; then :; fi
    ;;
  all)
    qa_require_tools go gcc cargo make bash
    ;;
esac
# infra lint requires shellcheck+yamllint; handle missing as blocked per check, but preflight lists them
if [[ "$DEST" == "infra" || "$DEST" == "all" ]]; then
  if ! command -v shellcheck >/dev/null 2>&1; then
    # not exit 2; record blocked at check time. But qa_require_tools would exit 2; skip here.
    :
  fi
fi

# ---------------- cleanup trap ----------------
_CLEANUP_DONE=0
cleanup() {
  if [[ $_CLEANUP_DONE -eq 1 ]]; then return 0; fi
  _CLEANUP_DONE=1
  if [[ $KEEP_DEPS -eq 1 ]]; then export QA_KEEP_DEPS=1; fi
  deps_down
}
if [[ $NO_DEPS -eq 0 ]]; then
  qa_trap_cleanup cleanup
fi

# ---------------- timeout default ----------------
stage_timeout() {
  local stage="$1"
  if [[ -n "$TIMEOUT_OVERRIDE" ]]; then echo "$TIMEOUT_OVERRIDE"; return; fi
  case "$stage" in
    lint) echo 300 ;;
    unit) echo "${QA_TIMEOUT_UNIT:-120}" ;;
    integration) echo "${QA_TIMEOUT_INTEGRATION:-600}" ;;
  esac
}

# ---------------- deps up helper ----------------
ensure_deps() {
  local svc="$1"
  if [[ $NO_DEPS -eq 1 ]]; then return 0; fi
  if [[ -z "${QA_IT_PROJECT:-}" ]]; then
    deps_up "$svc"
  fi
}

# ---------------- executors ----------------
run_doc_service() {
  local stage="$1"
  local dir="$WORKSPACE_ROOT/doc-service"
  local log="$ARTDIR/${stage}.log"
  case "$stage" in
    lint)
      # go vet
      run_check "doc-service" "lint" "go vet ./..." "$(stage_timeout lint)" "$log" \
        bash -c "cd '$dir' && go vet ./..."
      # gofmt
      log="$ARTDIR/lint.log"
      # append? keep separate not required; use same log append by reusing? We'll just run and record separate check name with same log
      local log2="$ARTDIR/lint-gofmt.log"
      run_check "doc-service" "lint" 'gofmt -l .' "$(stage_timeout lint)" "$log2" \
        bash -c 'test -z "$(gofmt -l .)" || (gofmt -l . && exit 1)'
      # move log2 content? leave; results name different. Not needed.
      ;;
    unit)
      local pkgs
      pkgs="$(cd "$dir" && go list ./... | grep -vE 'internal/adapters/(mongo|changestream|relay|redis)$')"
      run_check "doc-service" "unit" 'go test -race' "$(stage_timeout unit)" "$log" \
        bash -c "cd '$dir' && PKGS='$pkgs'; go test -race -count=1 \$PKGS"
      ;;
    integration)
      if [[ $NO_DEPS -eq 0 ]]; then ensure_deps "doc-service"; fi
      run_check "doc-service" "integration" 'go test adapters' "$(stage_timeout integration)" "$log" \
        bash -c "cd '$dir' && go test -race -count=1 ./internal/adapters/mongo/... ./internal/adapters/changestream/... ./internal/adapters/relay/... ./internal/adapters/redis/... ./internal/adapters/minio/... ./internal/metrics/..."
      ;;
  esac
}

run_extraction_worker() {
  local stage="$1"
  local dir="$WORKSPACE_ROOT/extraction-worker"
  local log="$ARTDIR/${stage}.log"
  case "$stage" in
    lint)
      run_check "extraction-worker" "lint" "cargo fmt --check" "$(stage_timeout lint)" "$log" \
        bash -c "cd '$dir' && cargo fmt --all -- --check"
      local l2="$ARTDIR/lint-clippy.log"
      run_check "extraction-worker" "lint" "cargo clippy" "$(stage_timeout lint)" "$l2" \
        bash -c "cd '$dir' && cargo clippy --all-targets --all-features -- -D warnings"
      local l3="$ARTDIR/lint-audit.log"
      run_check "extraction-worker" "lint" "cargo audit" "$(stage_timeout lint)" "$l3" \
        bash -c "cd '$dir' && cargo audit"
      local l4="$ARTDIR/lint-deny.log"
      run_check "extraction-worker" "lint" "cargo deny" "$(stage_timeout lint)" "$l4" \
        bash -c "cd '$dir' && cargo deny check bans licenses advisories"
      ;;
    unit)
      run_check "extraction-worker" "unit" "cargo test" "$(stage_timeout unit)" "$log" \
        bash -c "cd '$dir' && cargo test --all-features"
      ;;
    integration)
      if [[ $NO_DEPS -eq 0 ]]; then ensure_deps "extraction-worker"; fi
      run_check "extraction-worker" "integration" "cargo test --ignored" "$(stage_timeout integration)" "$log" \
        bash -c "cd '$dir' && cargo test --all-features" -- --ignored
      ;;
  esac
}

run_ocr_worker() {
  local stage="$1"
  local dir="$WORKSPACE_ROOT/extraction-worker"
  local log="$ARTDIR/${stage}.log"
  case "$stage" in
    lint)
      run_check "ocr-worker" "lint" "cargo fmt --check" "$(stage_timeout lint)" "$log" \
        bash -c "cd '$dir' && cargo fmt --all -- --check"
      local l2="$ARTDIR/lint-clippy-ocr.log"
      run_check "ocr-worker" "lint" "cargo clippy -p ocr-worker" "$(stage_timeout lint)" "$l2" \
        bash -c "cd '$dir' && cargo clippy -p ocr-worker --all-targets --all-features -- -D warnings"
      ;;
    unit)
      run_check "ocr-worker" "unit" "cargo test -p ocr-worker" "$(stage_timeout unit)" "$log" \
        bash -c "cd '$dir' && cargo test -p ocr-worker --all-features"
      ;;
    integration)
      if [[ $NO_DEPS -eq 0 ]]; then ensure_deps "ocr-worker"; fi
      # run; if 0 tests -> skip
      local tmp="$log.tmp2"
      local start end dur rc
      start=$(date +%s)
      if timeout "$(stage_timeout integration)" bash -c "cd '$dir' && cargo test -p ocr-worker --all-features -- --ignored" >"$tmp" 2>&1; then rc=0; else rc=$?; fi
      qa_redact <"$tmp" >"$log"; rm -f "$tmp"
      qa_truncate_file "$log" 5242880
      end=$(date +%s); dur=$((end-start))
      if grep -q "0 tests" "$log" 2>/dev/null; then
        results_record "ocr-worker · integration · cargo test --ignored" "skip" "$dur" "ocr-worker no tiene tests #[ignore]"
      else
        if [[ $rc -eq 124 ]]; then results_record "ocr-worker · integration · cargo test --ignored" "fail" "$dur" "timeout $(stage_timeout integration)s"
        elif [[ $rc -eq 0 ]]; then results_record "ocr-worker · integration · cargo test --ignored" "pass" "$dur" ""
        else results_record "ocr-worker · integration · cargo test --ignored" "fail" "$dur" "exit $rc"; fi
      fi
      ;;
  esac
}

run_platform_services() {
  local stage="$1"
  local dir="$WORKSPACE_ROOT/platform-services"
  local log="$ARTDIR/${stage}.log"
  case "$stage" in
    lint)
      run_check "platform-services" "lint" "make lint" "$(stage_timeout lint)" "$log" \
        make -C "$WORKSPACE_ROOT/platform-services" lint
      ;;
    unit)
      local l1="$ARTDIR/unit-ratelimiter.log"
      run_check "platform-services" "unit" "rate-limiter" "$(stage_timeout unit)" "$l1" \
        bash -c "cd '$WORKSPACE_ROOT/platform-services/rate-limiter' && go vet ./... && go test ./..."
      local l2="$ARTDIR/unit-slo.log"
      run_check "platform-services" "unit" "slo-exporter" "$(stage_timeout unit)" "$l2" \
        bash -c "cd '$WORKSPACE_ROOT/platform-services/slo-exporter' && go vet ./... && go test ./..."
      ;;
    integration)
      run_check "platform-services" "integration" "contract run.sh" "$(stage_timeout integration)" "$log" \
        bash -c "cd '$WORKSPACE_ROOT/platform-services' && tests/contract/run.sh"
      ;;
  esac
}

run_infra() {
  local stage="$1"
  local dir="$WORKSPACE_ROOT/infra"
  local log="$ARTDIR/${stage}.log"
  case "$stage" in
    lint)
      if command -v shellcheck >/dev/null 2>&1; then
        run_check "infra" "lint" "shellcheck" "$(stage_timeout lint)" "$log" \
          bash -c "cd '$dir' && shellcheck \$(git ls-files '*.sh')"
      else
        results_record "infra · lint · shellcheck" "blocked" "0" "shellcheck no instalado"
      fi
      local l2="$ARTDIR/lint-yamllint.log"
      run_check "infra" "lint" "yamllint" "$(stage_timeout lint)" "$l2" \
        bash -c "cd '$dir' && yamllint -d relaxed ."
      local l3="$ARTDIR/lint-bashn.log"
      run_check "infra" "lint" "bash -n" "$(stage_timeout lint)" "$l3" \
        bash -c "cd '$dir' && for f in \$(git ls-files '*.sh'); do bash -n \"\$f\" || exit 1; done"
      ;;
    unit)
      : # none
      ;;
    integration)
      local scripts=(scripts/verify-networks.sh scripts/test-routing-table.sh scripts/test-consul.sh scripts/verify-consul-boundaries.sh scripts/test-chain-alerts.sh)
      for s in "${scripts[@]}"; do
        local name; name="$(basename "$s")"
        local l="$ARTDIR/integration-$name.log"
        if [[ -f "$WORKSPACE_ROOT/infra/$s" ]]; then
          run_check "infra" "integration" "$name" "$(stage_timeout integration)" "$l" \
            bash -c "cd '$WORKSPACE_ROOT/infra' && '$s'"
        else
          results_record "infra · integration · $name" "skip" "0" "script missing"
        fi
      done
      ;;
  esac
}

# ---------------- dispatch ----------------
run_one_dest() {
  local dest="$1"
  for stage in "${SELECTORS[@]}"; do
    case "$stage" in
      lint) ;;
      unit) ;;
      integration) ;;
    esac
    case "$dest" in
      doc-service) run_doc_service "$stage" ;;
      extraction-worker) run_extraction_worker "$stage" ;;
      ocr-worker) run_ocr_worker "$stage" ;;
      platform-services) run_platform_services "$stage" ;;
      infra) run_infra "$stage" ;;
    esac
  done
}

if [[ "$DEST" == "all" ]]; then
  for d in doc-service extraction-worker ocr-worker platform-services infra; do
    run_one_dest "$d"
  done
else
  run_one_dest "$DEST"
fi

# ---------------- final ----------------
rc=0
results_finish "$ARTDIR" || rc=$?
echo "Artefactos: $ARTDIR" >&2
if [[ $JSON -eq 1 ]]; then
  cat "$ARTDIR/results.json"
fi
exit $rc
