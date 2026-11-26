#!/usr/bin/env bash
# canary-a3.sh — runbook S8-P1-A3 (segundo escalon de canary: 10 %).
# Automatiza preflight, cambio de peso 100/0 -> 90/10, validacion de
# distribucion, ventana de observacion de 2 h, rollback drill, prueba de
# reversion automatica (§8.2) y generacion de evidencia.
#
# Uso:
#   canary-a3.sh preflight
#   canary-a3.sh apply
#   canary-a3.sh measure
#   canary-a3.sh observe
#   canary-a3.sh rollback
#   canary-a3.sh reversion
#   canary-a3.sh run [--fast]
#
# Variables: MEASURE_N, MEASURE_RPS, OBSERVE_SAMPLES, OBSERVE_INTERVAL_SECONDS,
# PROBE_RPS, EVIDENCE_PATH, TRAEFIK_HTTPS_PORT.
#
# Codigos de salida: 0 ok | 2 uso | 10 preflight | 20 apply | 30 distribucion
# | 31 5xx en canary | 32 umbral de observacion | 40 rollback.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
INFRA="$REPO_ROOT/infra"
SET_WEIGHT="$INFRA/scripts/set-canary-weight.sh"
EVIDENCE_PATH="${EVIDENCE_PATH:-$INFRA/docs/evidencias/S8/S8-P1-A3-canary-10pct.txt}"
COMPOSE=(docker compose -p infra --env-file "$INFRA/.env" -f "$INFRA/compose/docker-compose.yml")

TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-8543}"
if [[ -f "$INFRA/.env" ]]; then
  val=$(grep -E '^TRAEFIK_HTTPS_PORT=' "$INFRA/.env" | tail -1 | cut -d= -f2-)
  [[ -n "$val" ]] && TRAEFIK_HTTPS_PORT="$val"
fi

MEASURE_N="${MEASURE_N:-1000}"
MEASURE_RPS="${MEASURE_RPS:-9}"
OBSERVE_SAMPLES="${OBSERVE_SAMPLES:-8}"
OBSERVE_INTERVAL_SECONDS="${OBSERVE_INTERVAL_SECONDS:-900}"
PROBE_RPS="${PROBE_RPS:-4}"

FAIL_CODE=0
ROLLBACK_OK=0
REVERSION_OK=0
CURRENT_PHASE=""
PROBE_PID=""
TRAEFIK_CID=""

ev(){ printf '%s\n' "$*" >>"$EVIDENCE_PATH"; }
say(){ printf '%s\n' "$*" | tee -a "$EVIDENCE_PATH"; }

traefik_cid(){
  if [[ -z "$TRAEFIK_CID" ]]; then
    TRAEFIK_CID=$(docker ps --filter name=infra-traefik-1 --format '{{.ID}}' | head -1)
  fi
  printf '%s\n' "$TRAEFIK_CID"
}
started_at(){ docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || true; }
health_of(){ docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo missing; }

current_weights(){
  python3 - "$INFRA/traefik/dynamic/routing.yml" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
children = d["http"]["services"]["r-api-v2-weighted"]["weighted"]["services"]
w = {c["name"]: c["weight"] for c in children}
print(w["docv2@docker"], w["docv2-canary"])
PY
}

alerts_json(){
  docker exec infra-alertmanager-1 wget -qO- \
    'http://localhost:9093/api/v2/alerts?active=true&silenced=false&inhibited=false&unprocessed=false' 2>/dev/null
}

alerts_names(){
  alerts_json | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
names = sorted({a["labels"].get("alertname", "?") for a in data
                if a.get("status", {}).get("state", "active") == "active"})
print(",".join(names))
'
}

new_integrity_alerts(){ # <baseline_names> <current_names>
  python3 - "$1" "$2" <<'PY'
import sys
baseline = set(filter(None, sys.argv[1].split(",")))
current = set(filter(None, sys.argv[2].split(",")))
integrity = {"DocsStuck", "DocsAccumulating", "DLQNotEmpty",
             "QueueDepthHigh", "PELBacklog", "ExtractionErrors"}
print(",".join(sorted((current - baseline) & integrity)))
PY
}

xlen(){
  docker exec infra-redis-streams-1 sh -c \
    'redis-cli -a "$(cat /run/secrets/redis_streams_password)" --no-auth-warning --json XLEN stream:pdf-processing' 2>/dev/null
}

xpending_count(){
  docker exec infra-redis-streams-1 sh -c \
    'redis-cli -a "$(cat /run/secrets/redis_streams_password)" --no-auth-warning --json XPENDING stream:pdf-processing extraction-workers' 2>/dev/null \
  | python3 -c '
import json, sys
try:
    v = json.load(sys.stdin)
    print(v[0] if isinstance(v, list) and v else 0)
except Exception:
    print("NA")
'
}

readyz(){
  docker exec infra-doc-service-1 wget -qO- http://localhost:8080/readyz 2>/dev/null || true
}

nonterminal_docs(){
  docker exec infra-mongo-1 sh -c \
    'mongosh --quiet -u "$MONGO_INITDB_ROOT_USERNAME" -p "$(cat /run/secrets/mongo_initdb_root_password)" --authenticationDatabase admin documents --eval "db.documents.countDocuments({status:{\$nin:[\"COMPLETED\",\"FAILED\",\"REJECTED\",\"UPLOAD_EXPIRED\"]},updated_at:{\$lt:new Date(Date.now()-600000)}})"' 2>/dev/null \
  | tail -1
}

# Parsea un fragmento del access log de Traefik y emite K=V para el router v2.
log_stats(){ # <fragment>
  python3 - "$1" <<'PY'
import json, sys

def p95(values):
    if not values:
        return None
    values = sorted(values)
    idx = max(0, min(len(values) - 1, int(round(0.95 * (len(values) - 1)))))
    return values[idx]

rows = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("RouterName") != "r-api-v2@file":
        continue
    name = e.get("ServiceName") or "unknown"
    r = rows.setdefault(name, {"n": 0, "err": 0, "dur": []})
    r["n"] += 1
    try:
        if int(e.get("DownstreamStatus", 0)) >= 500:
            r["err"] += 1
    except Exception:
        pass
    try:
        r["dur"].append(int(e.get("Duration", 0)))
    except Exception:
        pass

for name, r in sorted(rows.items()):
    p = p95(r["dur"])
    print(f'{name}_n={r["n"]}')
    print(f'{name}_err={r["err"]}')
    print(f'{name}_p95_ms={"NA" if p is None else round(p / 1_000_000)}')
PY
}

# Parsea el access log completo desde un corte temporal (ventana de baseline).
log_stats_since(){ # <full-log> <cutoff ISO>
  python3 - "$1" "$2" <<'PY'
import json, sys

def p95(values):
    if not values:
        return None
    values = sorted(values)
    idx = max(0, min(len(values) - 1, int(round(0.95 * (len(values) - 1)))))
    return values[idx]

rows = {}
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("RouterName") != "r-api-v2@file":
        continue
    if (e.get("StartUTC") or "") < sys.argv[2]:
        continue
    name = e.get("ServiceName") or "unknown"
    r = rows.setdefault(name, {"n": 0, "err": 0, "dur": []})
    r["n"] += 1
    try:
        if int(e.get("DownstreamStatus", 0)) >= 500:
            r["err"] += 1
    except Exception:
        pass
    try:
        r["dur"].append(int(e.get("Duration", 0)))
    except Exception:
        pass

for name, r in sorted(rows.items()):
    p = p95(r["dur"])
    print(f'{name}_n={r["n"]}')
    print(f'{name}_err={r["err"]}')
    print(f'{name}_p95_ms={"NA" if p is None else round(p / 1_000_000)}')
PY
}

kv(){ # <file> <key> -> valor o vacio
  sed -n "s/^$2=//p" "$1" | tail -1
}

preflight(){
  CURRENT_PHASE=preflight
  say "=== 1. PREFLIGHT ==="
  say "UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "infra commit: $(git -C "$INFRA" rev-parse --short HEAD)"

  for c in infra-doc-service-1 infra-doc-service-canary-1 infra-traefik-1; do
    st=$(health_of "$c")
    say "$c health=$st"
    [[ "$st" == "healthy" ]] || { say "FAIL preflight: $c no healthy ($st)"; exit 10; }
  done

  "$SET_WEIGHT" --check 90 10 >/dev/null
  "$SET_WEIGHT" --check 100 0 >/dev/null
  read -r cw1 cw2 <<<"$(current_weights)"
  say "pesos actuales: $cw1/$cw2"
  [[ "$cw1/$cw2" == "100/0" ]] || { say "FAIL preflight: pesos iniciales $cw1/$cw2 != 100/0"; exit 10; }

  TRAEFIK_CID=$(traefik_cid)
  [[ -n "$TRAEFIK_CID" ]] || { say "FAIL preflight: traefik no corriendo"; exit 10; }
  sa=$(started_at "$TRAEFIK_CID")
  say "Traefik StartedAt=$sa"
  printf '%s' "$sa" >/tmp/a3-traefik-startedat.before

  say "--- baseline de alertas (justificacion: preexistentes, no originadas por el canary) ---"
  alerts_names | tee -a "$EVIDENCE_PATH" >/tmp/a3-baseline-alerts.txt
  alerts_json | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = []
for a in data:
    print(a["labels"].get("alertname"), a["labels"].get("severity"), a.get("startsAt"))
' | tee -a "$EVIDENCE_PATH"

  say "--- baseline de Mongo (docs no terminales > 10 min) ---"
  nt=$(nonterminal_docs)
  nt="${nt:-NA}"
  say "nonterminal_docs=$nt"
  printf '%s' "$nt" >/tmp/a3-baseline-nonterminal.txt

  say "--- baseline de Redis (stream y PEL) ---"
  xl=$(xlen); xp=$(xpending_count)
  say "XLEN=$xl XPENDING_count=$xp"
  printf '%s' "$xl" >/tmp/a3-baseline-xlen.txt

  say "--- baseline de 15 min (access log, por ServiceName) ---"
  cutoff=$(date -u -d '15 minutes ago' +%Y-%m-%dT%H:%M:%S.%NZ)
  docker logs "$TRAEFIK_CID" >/tmp/a3-baseline.log 2>&1 || true
  log_stats_since /tmp/a3-baseline.log "$cutoff" | tee -a "$EVIDENCE_PATH" >/tmp/a3-baseline-stats.txt
  # Referencias: docv2 estable y monolito. Si no hay trafico, se registra NA.
  base_stable=$(kv /tmp/a3-baseline-stats.txt docv2@docker_p95_ms)
  base_mono=$(kv /tmp/a3-baseline-stats.txt legacy-monolito@file_p95_ms)
  say "referencia p95: docv2=${base_stable:-NA} monolito=${base_mono:-NA}"
}

apply(){
  CURRENT_PHASE=apply
  say "=== 2. CAMBIO DE PESO 100/0 -> 90/10 ==="
  say "comando: $SET_WEIGHT 90 10"
  cid=$(traefik_cid)
  before=$(started_at "$cid")
  echo "$before" >/tmp/a3-traefik-startedat.apply.before
  "$SET_WEIGHT" 90 10 2>&1 | tee -a "$EVIDENCE_PATH" || { say "FAIL apply: set-canary-weight.sh fallo"; exit 20; }
  after=$(started_at "$cid")
  say "StartedAt before=$before after=$after"
  [[ "$before" == "$after" ]] || { say "FAIL apply: Traefik se reinicio"; exit 20; }

  errs=$("${COMPOSE[@]}" logs --since 2m traefik 2>/dev/null | grep -iE 'error|invalid|cannot|failed' || true)
  say "grep errores de configuracion: ${errs:-<vacio>}"
  [[ -z "$errs" ]] || { say "FAIL apply: errores de configuracion en Traefik"; exit 20; }

  hc=$("${COMPOSE[@]}" exec -T traefik traefik healthcheck --ping 2>&1 || true)
  say "traefik healthcheck: ${hc:-<sin salida>}"

  for host in api.localhost; do
    code=$(curl -sk --resolve "${host}:${TRAEFIK_HTTPS_PORT}:127.0.0.1" -o /dev/null -w '%{http_code}' \
      "https://${host}:${TRAEFIK_HTTPS_PORT}/healthz")
    say "healthz ${host}: $code"
    [[ "$code" == "200" ]] || { say "FAIL apply: /healthz devolvio $code"; exit 20; }
  done
}

measure(){
  CURRENT_PHASE=measure
  say "=== 3. VALIDACION DE DISTRIBUCION (N=$MEASURE_N) ==="
  cid=$(traefik_cid)
  before=$(docker logs "$cid" 2>&1 | wc -l)
  say "log offset antes de medir=$before"

  set +e
  MEASURE_RPS="$MEASURE_RPS" "$SET_WEIGHT" --measure "$MEASURE_N" 2>&1 | tee -a "$EVIDENCE_PATH"
  measure_rc=${PIPESTATUS[0]}
  set -e

  sleep 2
  docker logs "$cid" 2>&1 | tail -n +$((before + 1)) >/tmp/a3-measure.log
  log_stats /tmp/a3-measure.log | tee -a "$EVIDENCE_PATH" >/tmp/a3-measure-stats.txt
  canary=$(kv /tmp/a3-measure-stats.txt docv2-canary@file_n); canary="${canary:-0}"
  c5xx=$(kv /tmp/a3-measure-stats.txt docv2-canary@file_err); c5xx="${c5xx:-0}"
  say "medicion: canary=$canary canary_5xx=$c5xx exit_measure=$measure_rc"

  if (( c5xx > 0 )); then
    say "No-Go por errores: $c5xx respuestas 5xx en el canary. Rollback inmediato."
    "$SET_WEIGHT" 100 0 >/dev/null 2>&1 || true
    exit 31
  fi
  if (( measure_rc != 0 )); then
    say "No-Go por distribucion: --measure salio $measure_rc."
    "$SET_WEIGHT" 100 0 >/dev/null 2>&1 || true
    exit 30
  fi
  say "Go: distribucion dentro de la banda y cero 5xx en la muestra."
}

probe_loop(){
  while true; do
    for ((i = 0; i < PROBE_RPS; i++)); do
      curl -sk --resolve "api.localhost:${TRAEFIK_HTTPS_PORT}:127.0.0.1" -o /dev/null \
        "https://api.localhost:${TRAEFIK_HTTPS_PORT}/api/v2/documents?page_size=1" || true
    done
    sleep 1
  done
}

observe(){
  CURRENT_PHASE=observe
  say "=== 4. OBSERVACION (samples=$OBSERVE_SAMPLES interval=${OBSERVE_INTERVAL_SECONDS}s probe=${PROBE_RPS}rps) ==="

  base_stable=$(kv /tmp/a3-baseline-stats.txt docv2@docker_p95_ms)
  base_mono=$(kv /tmp/a3-baseline-stats.txt legacy-monolito@file_p95_ms)
  base_nt=$(cat /tmp/a3-baseline-nonterminal.txt 2>/dev/null || echo NA)
  base_alerts=$(cat /tmp/a3-baseline-alerts.txt 2>/dev/null || echo "")
  base_xlen=$(cat /tmp/a3-baseline-xlen.txt 2>/dev/null || echo NA)

  say "| # | UTC | canary_n | canary_5xx | canary_err% | p95_canary_ms | p95_docv2_ms | nonterminal | XLEN | alertas | readyz | resultado |"
  say "|---|---|---|---|---|---|---|---|---|---|---|---|"

  probe_loop &
  PROBE_PID=$!

  cid=$(traefik_cid)
  offset=$(docker logs "$cid" 2>&1 | wc -l)
  cum_n=0; cum_err=0; failed=0; new_integrity_seen=""

  for ((s = 1; s <= OBSERVE_SAMPLES; s++)); do
    sleep "$OBSERVE_INTERVAL_SECONDS"
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    docker logs "$cid" 2>&1 | tail -n +$((offset + 1)) >/tmp/a3-sample.log
    offset=$(docker logs "$cid" 2>&1 | wc -l)
    log_stats /tmp/a3-sample.log >/tmp/a3-sample-stats.txt

    canary=$(kv /tmp/a3-sample-stats.txt docv2-canary@file_n); canary="${canary:-0}"
    c5xx=$(kv /tmp/a3-sample-stats.txt docv2-canary@file_err); c5xx="${c5xx:-0}"
    p95c=$(kv /tmp/a3-sample-stats.txt docv2-canary@file_p95_ms); p95c="${p95c:-NA}"
    p95s=$(kv /tmp/a3-sample-stats.txt docv2@docker_p95_ms); p95s="${p95s:-NA}"
    cum_n=$((cum_n + canary)); cum_err=$((cum_err + c5xx))

    nt=$(nonterminal_docs); nt="${nt:-NA}"
    xl=$(xlen); xp=$(xpending_count)
    cur_alerts=$(alerts_names)
    new_int=$(new_integrity_alerts "$base_alerts" "$cur_alerts")
    if [[ -n "$new_int" ]]; then new_integrity_seen="${new_integrity_seen:+$new_integrity_seen,}$new_int"; fi
    rz=$(readyz)

    verdict="OK"; reason=""
    if (( c5xx > 0 )); then verdict="FAIL"; reason="5xx_canary=$c5xx"; fi
    if [[ "$verdict" == "OK" && "$rz" != *'"ready"'* ]]; then verdict="FAIL"; reason="readyz"; fi
    if [[ "$verdict" == "OK" && "$nt" != "NA" && "$base_nt" != "NA" ]] && (( nt > base_nt )); then
      verdict="FAIL"; reason="docs_no_terminales=$nt>baseline=$base_nt"
    fi
    if [[ "$verdict" == "OK" && -n "$new_int" ]]; then verdict="FAIL"; reason="alertas_nuevas=$new_int"; fi
    if [[ "$verdict" == "OK" && "$p95c" != "NA" && "$p95s" != "NA" ]] && (( p95c > 2 * p95s )); then
      verdict="FAIL"; reason="p95_canary=${p95c}ms>2x_docv2=${p95s}ms"
    fi
    if [[ "$verdict" == "OK" && "$p95c" != "NA" && "$base_mono" != "" && "$base_mono" != "NA" ]] && (( p95c > 2 * base_mono )); then
      verdict="FAIL"; reason="p95_canary=${p95c}ms>2x_monolito=${base_mono}ms"
    fi

    err_pct="NA"; (( cum_n > 0 )) && err_pct=$(awk -v e="$cum_err" -v n="$cum_n" 'BEGIN{printf "%.2f", 100*e/n}')
    rz_state="FAIL"; [[ "$rz" == *'"ready"'* ]] && rz_state="ready"
    say "| $s | $ts | $canary | $c5xx | $err_pct | $p95c | $p95s | $nt | $xl/$xp | ${cur_alerts:-none} | $rz_state | $verdict${reason:+ ($reason)} |"

    if [[ "$verdict" == "FAIL" ]]; then
      failed=1
      say "Umbral superado en la muestra $s ($reason). Rollback inmediato."
      break
    fi
  done

  kill "$PROBE_PID" 2>/dev/null || true
  wait "$PROBE_PID" 2>/dev/null || true
  PROBE_PID=""

  say "cumulative: canary_n=$cum_n canary_5xx=$cum_err"
  [[ "$failed" == "0" ]] || FAIL_CODE=1
  return 0
}

rollback(){
  CURRENT_PHASE=rollback
  say "=== 5. ROLLBACK DRILL (90/10 -> 100/0) ==="
  read -r w1 w2 <<<"$(current_weights)"
  if [[ "$w1/$w2" != "90/10" ]]; then
    say "pesos en $w1/$w2; re-aplicando 90/10 para medir el drill."
    "$SET_WEIGHT" 90 10 2>&1 | tee -a "$EVIDENCE_PATH" || {
      say "FAIL rollback: no se pudo aplicar 90/10"; ROLLBACK_OK=0; return 0; }
  fi
  cid=$(traefik_cid)
  before_started=$(started_at "$cid")
  T0=$(date +%s)
  "$SET_WEIGHT" 100 0 2>&1 | tee -a "$EVIDENCE_PATH" || {
    say "FAIL rollback: set-canary-weight.sh fallo"; ROLLBACK_OK=0; return 0; }
  T1=$(date +%s)
  rs=$((T1 - T0))
  say "rollback_seconds=$rs"

  sa=$(started_at "$cid")
  say "StartedAt before=$before_started after=$sa"

  hc=$("${COMPOSE[@]}" exec -T traefik traefik healthcheck --ping 2>&1 || true)
  say "traefik healthcheck: ${hc:-<sin salida>}"

  cbefore=$(docker logs "$cid" 2>&1 | wc -l)
  for ((i = 1; i <= 1000; i++)); do
    curl -sk --resolve "api.localhost:${TRAEFIK_HTTPS_PORT}:127.0.0.1" -o /dev/null \
      "https://api.localhost:${TRAEFIK_HTTPS_PORT}/api/v2/documents?page_size=1" || true
    if (( i % 9 == 0 )); then sleep 1; fi
  done
  sleep 2
  docker logs "$cid" 2>&1 | tail -n +$((cbefore + 1)) >/tmp/a3-rollback.log
  log_stats /tmp/a3-rollback.log | tee -a "$EVIDENCE_PATH" >/tmp/a3-rollback-stats.txt
  rcanary=$(kv /tmp/a3-rollback-stats.txt docv2-canary@file_n); rcanary="${rcanary:-0}"
  rstable=$(kv /tmp/a3-rollback-stats.txt docv2@docker_n); rstable="${rstable:-0}"
  say "distribucion post-rollback: docv2@docker=$rstable canary=$rcanary"

  if (( rs >= 60 )); then say "FAIL rollback: ${rs}s >= 60s"; ROLLBACK_OK=0; return 0; fi
  if [[ "$before_started" != "$sa" ]]; then say "FAIL rollback: Traefik se reinicio"; ROLLBACK_OK=0; return 0; fi
  if (( rcanary > 0 )); then say "FAIL rollback: el canary sigue recibiendo $rcanary peticiones"; ROLLBACK_OK=0; return 0; fi
  if (( rstable < 950 )); then say "FAIL rollback: muestra insuficiente ($rstable/1000)"; ROLLBACK_OK=0; return 0; fi
  ROLLBACK_OK=1
  say "rollback OK (<60s, 100 % al estable, sin reinicio)."
}

canary_5xx_since(){ # <log-file> -> numero de 5xx del canary en el fragmento
  python3 - "$1" <<'PY'
import json, sys
n = 0
for line in open(sys.argv[1]):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
    except Exception:
        continue
    if e.get("RouterName") != "r-api-v2@file":
        continue
    if e.get("ServiceName") != "docv2-canary@file":
        continue
    try:
        if int(e.get("DownstreamStatus", 0)) >= 500:
            n += 1
    except Exception:
        pass
print(n)
PY
}

reversion(){
  CURRENT_PHASE=reversion
  say "=== 6. REVERSION AUTOMATICA (§8.2) ==="
  read -r w1 w2 <<<"$(current_weights)"
  if [[ "$w1/$w2" != "90/10" ]]; then
    say "pesos en $w1/$w2; re-aplicando 90/10 para la prueba."
    "$SET_WEIGHT" 90 10 2>&1 | tee -a "$EVIDENCE_PATH" || {
      say "FAIL reversion: no se pudo aplicar 90/10"; REVERSION_OK=0; return 0; }
  fi
  cid=$(traefik_cid)
  before_started=$(started_at "$cid")
  offset=$(docker logs "$cid" 2>&1 | wc -l)

  inj=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  say "injection_ts=$inj"
  say "signal: DownstreamStatus>=500 con ServiceName=docv2-canary@file en access log de Traefik"
  probe_loop &
  PROBE_PID=$!
  "${COMPOSE[@]}" --profile full stop doc-service-canary 2>&1 | tee -a "$EVIDENCE_PATH" || true

  det=""; cnt=0; t0=$(date +%s)
  while :; do
    sleep 15
    docker logs "$cid" 2>&1 | tail -n +$((offset + 1)) >/tmp/a3-reversion.log
    offset=$(docker logs "$cid" 2>&1 | wc -l)
    cnt=$(canary_5xx_since /tmp/a3-reversion.log)
    if (( cnt > 0 )); then
      det=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      break
    fi
    if [[ $(( $(date +%s) - t0 )) -ge 300 ]]; then break; fi
  done
  say "canary_5xx_observados=$cnt"
  if [[ -n "$det" ]]; then say "detection_ts=$det"; else say "detection_ts=NA"; fi

  T0=$(date +%s)
  "$SET_WEIGHT" 100 0 2>&1 | tee -a "$EVIDENCE_PATH" || true
  T1=$(date +%s)
  rev_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  say "reversion_ts=$rev_ts reversion_seconds=$((T1 - T0))"

  "${COMPOSE[@]}" --profile full start doc-service-canary 2>&1 | tee -a "$EVIDENCE_PATH" || true
  st=""
  for i in $(seq 1 24); do
    st=$(health_of infra-doc-service-canary-1)
    [[ "$st" == "healthy" ]] && break
    sleep 5
  done
  say "canary health after restore=$st"

  if [[ -n "$PROBE_PID" ]]; then
    kill "$PROBE_PID" 2>/dev/null || true
    wait "$PROBE_PID" 2>/dev/null || true
    PROBE_PID=""
  fi

  sa=$(started_at "$cid")
  say "StartedAt before=$before_started after=$sa"
  say "pesos post-reversion: $(current_weights)"
  say "Gap declarado: no existe alerta canary-error-especifica (HighErrorRate/DocServiceNotReady son genericas); la deteccion se hace por access log. Owner P1/P4."

  if [[ -n "$det" && $((T1 - T0)) -lt 60 && "$sa" == "$before_started" && "$st" == "healthy" ]]; then
    REVERSION_OK=1
    say "reversion OK: deteccion dentro de la ventana de 5 min, rollback <60 s, sin reinicio, canary restaurado healthy."
  else
    REVERSION_OK=0
    say "FAIL reversion: deteccion/rollback/restauracion no cumplieron el criterio."
  fi
}

evidence(){
  CURRENT_PHASE=evidence
  read -r w1 w2 <<<"$(current_weights)"
  final="No-Go"
  if [[ "$FAIL_CODE" == "0" && "$ROLLBACK_OK" == "1" && "$REVERSION_OK" == "1" && "$w1/$w2" == "100/0" ]]; then
    final="Go"
  fi
  say "=== 7. DECISION ==="
  say "DECISION: $final"
  say "pesos finales: $w1/$w2"
  say "observacion_fail=$FAIL_CODE rollback_ok=$ROLLBACK_OK reversion_ok=$REVERSION_OK"
  if [[ "$final" == "Go" ]]; then
    say "A3 (10 %) sostenido: muestras sin umbral §9.5, rollback drill <60 s, reversion automatica probada, canary de migracion en 0 %."
  else
    say "A3 (10 %) BLOQUEADO: alguna muestra fallo, hubo 5xx, el rollback o la reversion no cumplieron. Registrar la causa antes de reintentar."
  fi
  say ""
  say "=== 8. DESVIACIONES RESPECTO DE docs/S8/tasks/task-6.md ==="
  say "1. El comando literal del runbook (set-canary-weight.sh r-api-v2-weighted docv2 90 docv2-canary 10) no coincide con la interfaz real del script; se usa: set-canary-weight.sh 90 10."
  say "2. Las metricas por backend se toman del access log de Traefik (RouterName=r-api-v2@file, ServiceName docv2@file|docv2-canary@file) porque http_requests_total{service=\"doc-service-canary\"} no existe: Prometheus solo scrapea doc-service."
  say "3. La comparacion de p95 usa docv2 estable como referencia principal; el monolito se registra si tiene trafico en la ventana de baseline (en este laboratorio puede ser NA)."
  say "4. Orden ejecutado: preflight -> apply -> measure -> observe -> rollback drill -> reversion. La prueba de reversion (§8.2) re-aplica 90/10 si los pesos ya estan en 100/0 y termina en 100/0."
}

cleanup(){
  if [[ -n "$PROBE_PID" ]]; then kill "$PROBE_PID" 2>/dev/null || true; fi
  "${COMPOSE[@]}" --profile full start doc-service-canary >/dev/null 2>&1 || true
  if [[ -f "$INFRA/traefik/dynamic/routing.yml" ]]; then
    read -r w1 w2 <<<"$(current_weights 2>/dev/null || echo '100 0')"
    if [[ "$w1/$w2" != "100/0" ]]; then
      "$SET_WEIGHT" 100 0 >/dev/null 2>&1 || true
    fi
  fi
}

run(){
  local fast="${1:-0}"
  if [[ "$fast" == "1" ]]; then
    MEASURE_N=200
    OBSERVE_SAMPLES=2
    OBSERVE_INTERVAL_SECONDS=20
    EVIDENCE_PATH="/tmp/a3-selftest.txt"
  fi
  : >"$EVIDENCE_PATH"
  trap cleanup EXIT

  say "# S8-P1-A3 — segundo peso de canary 10 % (evidencia)"
  say ""
  say "Fecha UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  say "Commit infra: $(git -C "$INFRA" rev-parse --short HEAD)"
  say "Entorno: stack local infra (Traefik, api.localhost:${TRAEFIK_HTTPS_PORT})"
  say "Alcance: r-api-v2-weighted (docv2 / docv2-canary). Canary de migracion (r-inv-*) sin tocar."
  say ""

  preflight
  apply
  measure
  observe
  rollback
  reversion
  evidence

  trap - EXIT
  if [[ "$FAIL_CODE" != "0" ]]; then exit 32; fi
}

CMD=""
FAST=0
for a in "$@"; do
  case "$a" in
    --fast) FAST=1 ;;
    run|preflight|apply|measure|observe|rollback|reversion) CMD="$a" ;;
    *) echo "ERROR: argumento desconocido: $a"; exit 2 ;;
  esac
done

case "$CMD" in
  preflight) preflight ;;
  apply) apply ;;
  measure) measure ;;
  observe) observe ;;
  rollback) rollback ;;
  reversion) reversion ;;
  run) run "$FAST" ;;
  *) echo "usage: $0 {preflight|apply|measure|observe|rollback|reversion|run [--fast]}"; exit 2 ;;
esac
echo "PHASE_OK: $CURRENT_PHASE"
