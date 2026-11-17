#!/usr/bin/env bash
# set-canary-weight.sh — aplica, valida y revierte los pesos del canary de
# despliegue (S8-P1-03) sobre el servicio `weighted` del file provider.
#
# Uso:
#   set-canary-weight.sh [--check] <weight_primary> <weight_canary>
#   set-canary-weight.sh --rollback
#   set-canary-weight.sh --measure [N]
#
# Modos:
#   (sin flags)  aplica los pesos de forma atomica y verifica la recarga.
#   --check      valida argumentos y estructura sin escribir nada.
#   --rollback   restaura el backup previo y verifica recarga/salud.
#   --measure N  envia N peticiones y valida la distribucion con banda ±3σ.
#
# Codigos de salida:
#   0 ok | 2 argumentos/precondicion | 3 YAML invalido | 4 recarga no detectada
#   5 healthcheck o StartedAt | 6 sin backup | 7 distribucion fuera de tolerancia
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CANARY_ROUTING_FILE="${CANARY_ROUTING_FILE:-$REPO_ROOT/infra/traefik/dynamic/routing.yml}"
CANARY_WEIGHTED_SERVICE="${CANARY_WEIGHTED_SERVICE:-r-api-v2-weighted}"
CANARY_PRIMARY_NAME="${CANARY_PRIMARY_NAME:-docv2}"
CANARY_CANARY_NAME="${CANARY_CANARY_NAME:-docv2-canary}"

BACKUP="${CANARY_ROUTING_FILE}.bak"
TMPFILE=""
TMPLOG=""

COMPOSE_CMD=(docker compose -p infra --env-file "$REPO_ROOT/infra/.env" -f "$REPO_ROOT/infra/compose/docker-compose.yml")

cleanup() {
  [[ -n "$TMPFILE" ]] && rm -f "$TMPFILE"
  [[ -n "$TMPLOG" ]] && rm -f "$TMPLOG"
  return 0
}
trap cleanup EXIT

usage() {
  sed -n '4,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

is_int() { [[ "$1" =~ ^[0-9]+$ ]]; }

TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-8543}"
if [[ -f "$REPO_ROOT/infra/.env" ]]; then
  val=$(grep -E '^TRAEFIK_HTTPS_PORT=' "$REPO_ROOT/infra/.env" | tail -1 | cut -d= -f2-)
  [[ -n "$val" ]] && TRAEFIK_HTTPS_PORT="$val"
fi

container_id() {
  docker ps --filter "name=traefik" --format '{{.ID}}' | head -1
}

monolito_id() {
  docker ps --filter "name=monolito" --format '{{.ID}}' | head -1
}

started_at() {
  docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null || true
}

health_status() {
  docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null || echo "none"
}

canary_service_exists() {
  # `config --services` se captura completo antes del grep: con `pipefail`,
  # un `grep -q` que corta temprano le manda SIGPIPE a docker compose y el
  # pipeline falla aunque el servicio exista.
  local services attempt
  for attempt in 1 2 3; do
    if services=$("${COMPOSE_CMD[@]}" --profile full config --services 2>/dev/null); then
      grep -qx "doc-service-canary" <<<"$services"
      return
    fi
    sleep 0.3
  done
  return 1
}

# Lee los pesos actuales del par y los imprime como "<primario> <canary>".
current_weights() {
  python3 - "$CANARY_ROUTING_FILE" "$CANARY_WEIGHTED_SERVICE" "$CANARY_PRIMARY_NAME" "$CANARY_CANARY_NAME" <<'PY'
import sys, yaml
path, svc, prim, can = sys.argv[1:5]
d = yaml.safe_load(open(path))
children = d["http"]["services"][svc]["weighted"]["services"]
w = {c["name"]: c["weight"] for c in children}
print(w[prim], w[can])
PY
}

validate_structure() {
  python3 - "$CANARY_ROUTING_FILE" "$CANARY_WEIGHTED_SERVICE" "$CANARY_PRIMARY_NAME" "$CANARY_CANARY_NAME" <<'PY'
import sys, yaml
path, svc, prim, can = sys.argv[1:5]
try:
    d = yaml.safe_load(open(path))
except Exception as exc:  # noqa: BLE001
    print(f"ERROR: YAML invalido: {exc}")
    sys.exit(2)
services = (d.get("http") or {}).get("services") or {}
if svc not in services:
    print(f"ERROR: servicio {svc} no encontrado")
    sys.exit(2)
children = ((services[svc] or {}).get("weighted") or {}).get("services") or []
names = [c.get("name") for c in children]
for name in (prim, can):
    if name not in names:
        print(f"ERROR: hijo {name} no encontrado en {svc}")
        sys.exit(2)
PY
}

# Edicion por lineas: toca SOLO las dos lineas `weight:` del par, preservando
# comentarios y formato. Escribe el resultado en $TMPFILE.
apply_weights() {
  local w1="$1" w2="$2"
  python3 - "$CANARY_ROUTING_FILE" "$TMPFILE" "$CANARY_WEIGHTED_SERVICE" \
    "$CANARY_PRIMARY_NAME" "$CANARY_CANARY_NAME" "$w1" "$w2" <<'PY'
import sys
path, tmp, svc, prim, can, w1, w2 = sys.argv[1:8]
lines = open(path).read().splitlines(keepends=True)
in_service = in_block = False
current = None
out = []
for line in lines:
    stripped = line.strip()
    if not in_service:
        out.append(line)
        if stripped == svc + ":":
            in_service = True
        continue
    if not in_block:
        out.append(line)
        if stripped == "weighted:":
            in_block = True
        continue
    # Fin del bloque: un hermano de servicio (indent 4) o menos indentacion.
    if stripped and (len(line) - len(line.lstrip())) <= 4 and ":" in stripped:
        in_block = False
        in_service = False
        out.append(line)
        continue
    if stripped.startswith("- name:"):
        current = stripped.split(":", 1)[1].strip()
        out.append(line)
        continue
    if stripped.startswith("weight:") and current in (prim, can):
        new_w = w1 if current == prim else w2
        out.append(" " * (len(line) - len(line.lstrip())) + f"weight: {new_w}\n")
        continue
    out.append(line)
open(tmp, "w").write("".join(out))
PY
}

# Verifica que la unica diferencia semantica sean los dos pesos.
assert_only_weights_changed() {
  python3 - "$CANARY_ROUTING_FILE" "$TMPFILE" "$CANARY_WEIGHTED_SERVICE" \
    "$CANARY_PRIMARY_NAME" "$CANARY_CANARY_NAME" <<'PY'
import copy, sys, yaml
orig_path, new_path, svc, prim, can = sys.argv[1:6]
o = yaml.safe_load(open(orig_path))
n = yaml.safe_load(open(new_path))

def norm(d):
    d = copy.deepcopy(d)
    for child in d["http"]["services"][svc]["weighted"]["services"]:
        if child["name"] in (prim, can):
            child["weight"] = None
    return d

if norm(o) != norm(n):
    print("ERROR: la estructura cambio mas alla de los pesos")
    sys.exit(1)
PY
}

# Cuenta ServiceName observados para el router ponderado entre dos offsets.
count_services() {
  local cid="$1" before="$2"
  docker logs "$cid" 2>&1 | tail -n +$((before + 1)) | python3 -c '
import json, sys
counts = {}
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except Exception:
        continue
    if entry.get("RouterName") != "r-api-v2@file":
        continue
    name = entry.get("ServiceName")
    if not name:
        continue
    counts[name] = counts.get(name, 0) + 1
for name, n in counts.items():
    print(n, name)
'
}

probe_requests() {
  local n="$1" i
  for ((i = 1; i <= n; i++)); do
    curl -sk --resolve "api.localhost:${TRAEFIK_HTTPS_PORT}:127.0.0.1" -o /dev/null \
      "https://api.localhost:${TRAEFIK_HTTPS_PORT}/api/v2/documents?page_size=1" || true
    if (( i % 10 == 0 )); then sleep 1; fi
  done
}

# Verifica que la configuracion aplicada ya este activa. Devuelve 0 si la
# distribucion observada es coherente con los pesos; 1 si no se detecta.
wait_reload() {
  local w2="$1" cid round before counts canary_count
  cid=$(container_id)
  [[ -z "$cid" ]] && return 0
  for round in 1 2 3 4 5 6 7 8 9 10; do
    before=$(docker logs "$cid" 2>&1 | wc -l)
    probe_requests 60
    counts=$(count_services "$cid" "$before")
    canary_count=$(awk -v canary="$CANARY_CANARY_NAME@file" '$2 == canary {print $1}' <<<"$counts")
    canary_count="${canary_count:-0}"
    if (( w2 > 0 )); then
      (( canary_count >= 1 )) && return 0
    else
      (( canary_count == 0 )) && return 0
    fi
  done
  return 1
}

check_health_unchanged() {
  local cid="$1" mon_cid="$2" tra_before="$3" mon_before="$4"
  local hs
  hs=$(health_status "$cid")
  if [[ "$hs" != "healthy" && "$hs" != "none" ]]; then
    echo "ERROR: healthcheck falla (traefik: $hs)"
    return 1
  fi
  if [[ -n "$tra_before" && "$(started_at "$cid")" != "$tra_before" ]]; then
    echo "ERROR: healthcheck falla (traefik reiniciado)"
    return 1
  fi
  if [[ -n "$mon_cid" && -n "$mon_before" && "$(started_at "$mon_cid")" != "$mon_before" ]]; then
    echo "ERROR: healthcheck falla (monolito reiniciado)"
    return 1
  fi
  return 0
}

restore_backup() {
  if [[ -f "$BACKUP" ]]; then
    mv "$BACKUP" "$CANARY_ROUTING_FILE"
    chmod 644 "$CANARY_ROUTING_FILE"
  fi
}

# ---- parseo de argumentos (flags en cualquier posicion) -------------------
CHECK=0
ROLLBACK=0
MEASURE=0
MEASURE_N=""
POSITIONAL=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --check) CHECK=1; shift ;;
    --rollback) ROLLBACK=1; shift ;;
    --measure)
      MEASURE=1
      shift
      if [[ $# -gt 0 && "$1" =~ ^[0-9]+$ ]]; then
        MEASURE_N="$1"
        shift
      fi
      ;;
    --measure=*)
      MEASURE=1
      MEASURE_N="${1#--measure=}"
      shift
      ;;
    -h|--help) usage; exit 0 ;;
    --) shift; while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done ;;
    -*) echo "ERROR: opcion desconocida: $1"; exit 2 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# ---- modo rollback --------------------------------------------------------
if [[ "$ROLLBACK" == "1" ]]; then
  if [[ ! -f "$BACKUP" ]]; then
    echo "ERROR: sin backup"
    exit 6
  fi
  cid=$(container_id)
  mon_cid=$(monolito_id)
  tra_before=""; mon_before=""
  [[ -n "$cid" ]] && tra_before=$(started_at "$cid")
  [[ -n "$mon_cid" ]] && mon_before=$(started_at "$mon_cid")

  restore_backup
  if ! validate_structure; then
    echo "ERROR: YAML invalido, rollback"
    exit 3
  fi
  read -r _w1 w2 <<<"$(current_weights)"
  if [[ -n "$cid" ]] && ! wait_reload "$w2"; then
    echo "ERROR: recarga no detectada"
    exit 4
  fi
  if [[ -n "$cid" ]] && ! check_health_unchanged "$cid" "$mon_cid" "$tra_before" "$mon_before"; then
    exit 5
  fi
  echo "rollback ok"
  exit 0
fi

# ---- modo measure ---------------------------------------------------------
if [[ "$MEASURE" == "1" ]]; then
  N="${MEASURE_N:-1000}"
  RPS="${MEASURE_RPS:-9}"
  if ! is_int "$N" || (( N <= 0 )); then
    echo "ERROR: N invalido"
    exit 2
  fi
  if ! is_int "$RPS" || (( RPS <= 0 )); then
    echo "ERROR: MEASURE_RPS invalido"
    exit 2
  fi
  if ! validate_structure; then
    exit 2
  fi
  cid=$(container_id)
  if [[ -z "$cid" ]]; then
    echo "ERROR: recarga no detectada (traefik no corriendo)"
    exit 4
  fi
  read -r w1 w2 <<<"$(current_weights)"
  echo "pesos configurados: $w1/$w2 — N=$N rate=${RPS}/s"

  TMPLOG=$(mktemp)
  before=$(docker logs "$cid" 2>&1 | wc -l)
  for ((i = 1; i <= N; i++)); do
    curl -sk --resolve "api.localhost:${TRAEFIK_HTTPS_PORT}:127.0.0.1" -o /dev/null \
      "https://api.localhost:${TRAEFIK_HTTPS_PORT}/api/v2/documents?page_size=1" || true
    if (( i % RPS == 0 )); then sleep 1; fi
  done
  sleep 2
  docker logs "$cid" 2>&1 | tail -n +$((before + 1)) >"$TMPLOG"

  set +e
  python3 - "$TMPLOG" "$N" "$w1" "$w2" "$CANARY_PRIMARY_NAME@file" "$CANARY_CANARY_NAME@file" <<'PY'
import json, math, sys
path, n, w1, w2, prim, can = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]), sys.argv[5], sys.argv[6]
counts = {}
ignored = 0
for line in open(path):
    line = line.strip()
    if not line:
        continue
    try:
        entry = json.loads(line)
    except Exception:
        continue
    if entry.get("RouterName") != "r-api-v2@file":
        continue
    name = entry.get("ServiceName")
    if not name:
        ignored += 1
        continue
    counts[name] = counts.get(name, 0) + 1

total = counts.get(prim, 0) + counts.get(can, 0)
p = w2 / (w1 + w2)
expected = n * p
sigma = math.sqrt(n * p * (1 - p)) if 0 < p < 1 else 0.0
low, high = expected - 3 * sigma, expected + 3 * sigma

print(f"observado {prim}: {counts.get(prim, 0)}")
print(f"observado {can}: {counts.get(can, 0)}")
print(f"peticiones contabilizadas: {total}/{n} (ignoradas sin ServiceName: {ignored})")
if total:
    print(f"proporcion canary observada: {100.0 * counts.get(can, 0) / total:.2f}%")
print(f"esperado canary: {100.0 * p:.2f}% — banda ±3σ: [{low:.2f}, {high:.2f}] sobre {n}")

if total < 0.95 * n:
    print("ERROR: distribucion fuera de tolerancia (muestra insuficiente por 429)")
    sys.exit(7)
if not (low <= counts.get(can, 0) <= high):
    print("ERROR: distribucion fuera de tolerancia")
    sys.exit(7)
print("OK: distribucion dentro de la banda ±3σ")
PY
  rc=$?
  set -e
  exit "$rc"
fi

# ---- modo aplicar / check -------------------------------------------------
if [[ ${#POSITIONAL[@]} -ne 2 ]]; then
  usage
  exit 2
fi
W1="${POSITIONAL[0]}"
W2="${POSITIONAL[1]}"

if ! is_int "$W1" || ! is_int "$W2"; then
  echo "ERROR: pesos deben ser enteros no negativos"
  exit 2
fi
if (( W1 + W2 != 100 )); then
  echo "ERROR: la suma debe ser 100"
  exit 2
fi
if (( W1 == 0 && W2 == 0 )); then
  echo "ERROR: al menos un hijo > 0"
  exit 2
fi

if ! validate_structure; then
  exit 2
fi

if (( W2 > 0 )) && ! canary_service_exists; then
  echo "ERROR: doc-service-canary no declarado en compose"
  exit 2
fi

read -r CW1 CW2 <<<"$(current_weights)"
echo "pesos actuales: $CW1/$CW2"
echo "pesos solicitados: $W1/$W2"

if [[ "$CHECK" == "1" ]]; then
  exit 0
fi

cid=$(container_id)
mon_cid=$(monolito_id)
TRA_BEFORE=""
MON_BEFORE=""
[[ -n "$cid" ]] && TRA_BEFORE=$(started_at "$cid")
[[ -n "$mon_cid" ]] && MON_BEFORE=$(started_at "$mon_cid")

if (( CW1 == W1 && CW2 == W2 )); then
  echo "sin cambios"
  if [[ -n "$cid" ]]; then
    wait_reload "$W2" || { echo "ERROR: recarga no detectada"; exit 4; }
    check_health_unchanged "$cid" "$mon_cid" "$TRA_BEFORE" "$MON_BEFORE" || exit 5
  else
    echo "WARN: traefik no corriendo; pesos ya aplicados en disco"
  fi
  exit 0
fi

cp -p "$CANARY_ROUTING_FILE" "$BACKUP"
TMPFILE="${CANARY_ROUTING_FILE}.tmp"
apply_weights "$W1" "$W2"

if ! python3 -c "import yaml; yaml.safe_load(open('$TMPFILE'))" >/dev/null 2>&1; then
  restore_backup
  echo "ERROR: YAML invalido, rollback"
  exit 3
fi

if ! assert_only_weights_changed; then
  restore_backup
  echo "ERROR: YAML invalido, rollback"
  exit 3
fi

chmod 644 "$TMPFILE"
mv "$TMPFILE" "$CANARY_ROUTING_FILE"
TMPFILE=""

if [[ -z "$cid" ]]; then
  echo "WARN: traefik no corriendo; pesos aplicados y validados en disco"
  exit 0
fi

if ! wait_reload "$W2"; then
  restore_backup
  echo "ERROR: recarga no detectada"
  exit 4
fi

if ! check_health_unchanged "$cid" "$mon_cid" "$TRA_BEFORE" "$MON_BEFORE"; then
  restore_backup
  exit 5
fi

echo "aplicado: $W1/$W2"
exit 0
