#!/usr/bin/env bash
# S5-P1-04 — Llenado aislado de MinIO para probar los umbrales 70/85.
#
# NO toca el volumen infra_minio-data ni el disco del host: el data dir de MinIO
# vive en un tmpfs de 512 MiB dentro del proyecto Compose s5p104-minio.
#
# Requisitos:
#   - docker + docker compose v2
#   - curl y python3 en el host
#
# Variables de entorno (opcionales):
#   S5P104_WAIT_HIGH       segundos maximos de espera para MinioDiskHigh   (420)
#   S5P104_WAIT_CRITICAL   segundos maximos de espera para MinioDiskCritical (420)
#
# Exit codes: 0 = ambos dispararon; 4 = llenado/estado incompleto; otro = fallo
# de precondicion (tmpfs no verificable, stack no sano, etc.).
set -euo pipefail

COMPOSE_FILE="compose/docker-compose.test-minio-disk.yml"
PROJECT="s5p104-minio"
MINIO_SERVICE="minio-test"
DATA_DIR="/bitnami/minio/data"
EXPECTED_TMPFS_SIZE="512m"
PROM_URL="http://127.0.0.1:19090"
AM_URL="http://127.0.0.1:19093"
WAIT_HIGH="${S5P104_WAIT_HIGH:-420}"
WAIT_CRITICAL="${S5P104_WAIT_CRITICAL:-420}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

dc() { docker compose -f "$COMPOSE_FILE" -p "$PROJECT" "$@"; }

cleanup() {
  log "Bajando el stack aislado y eliminando recursos del proyecto $PROJECT"
  dc down -v --remove-orphans >/dev/null 2>&1 || true
}
trap cleanup EXIT

api_query() {
  # $1 = expresion PromQL; imprime el primer valor escalar o vacio.
  curl -sfG "$PROM_URL/api/v1/query" --data-urlencode "query=$1" |
    python3 -c 'import json,sys
d=json.load(sys.stdin)
r=d.get("data",{}).get("result",[])
print(r[0]["value"][1] if r else "")'
}

alert_state() {
  # $1 = alertname; imprime firing|pending|inactive|absent
  curl -sf "$PROM_URL/api/v1/alerts" |
    python3 -c 'import json,sys
name=sys.argv[1]
alerts=json.load(sys.stdin).get("data",{}).get("alerts",[])
states=[a.get("state") for a in alerts if a.get("labels",{}).get("alertname")==name]
print(states[0] if states else "absent")' "$1"
}

am_received() {
  # $1 = alertname; exit 0 si Alertmanager la tiene, 1 si no.
  curl -sf "$AM_URL/api/v2/alerts" |
    python3 -c 'import json,sys
name=sys.argv[1]
alerts=json.load(sys.stdin)
sys.exit(0 if any(a.get("labels",{}).get("alertname")==name for a in alerts) else 1)' "$1"
}

wait_http() {
  local url="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    curl -sf "$url" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}

wait_metric() {
  # $1 = expresion PromQL; espera hasta que Prometheus devuelva un valor.
  local expr="$1" tries="${2:-90}"
  for _ in $(seq 1 "$tries"); do
    [[ -n "$(api_query "$expr")" ]] && return 0
    sleep 1
  done
  return 1
}

tmpfs_usage() {
  # uso real del tmpfs del data dir (independiente del refresco de MinIO).
  dc exec -T "$MINIO_SERVICE" sh -c \
    "df -B1 $DATA_DIR | tail -1 | awk '{printf \"%.4f\", \$3/\$2}'"
}

wait_mib_to_pct() {
  # $1 = porcentaje objetivo; $2 = sufijo del archivo; imprime "start end"
  local pct="$1" tag="$2"
  local total free used target_mib current_mib to_write_mib
  total="$(api_query 'minio_cluster_capacity_usable_total_bytes')"
  free="$(api_query 'minio_cluster_capacity_usable_free_bytes')"
  if [[ -z "$total" || -z "$free" ]]; then
    log "ERROR: Prometheus no devolvio capacidad usable de MinIO" >&2
    return 5
  fi
  to_write_mib="$(python3 -c 'import sys,math
total=float(sys.argv[1]); free=float(sys.argv[2]); pct=float(sys.argv[3])
target=total*pct/100.0
used=total-free
need=target-used
print(max(0,int(math.ceil(need/(1024*1024)))))' "$total" "$free" "$pct")"
  local start end
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  if [[ "$to_write_mib" -gt 0 ]]; then
    dc exec -T "$MINIO_SERVICE" sh -c \
      "dd if=/dev/zero of=$DATA_DIR/fill-$tag.bin bs=1M count=$to_write_mib status=none"
  fi
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '%s %s\n' "$start" "$end"
}

verify_isolated_tmpfs() {
  local cid
  cid="$(dc ps -q "$MINIO_SERVICE")"
  if [[ -z "$cid" ]]; then
    log "ERROR: no hay contenedor $MINIO_SERVICE en el proyecto $PROJECT" >&2
    return 2
  fi
  docker inspect "$cid" | python3 -c 'import json,sys
data_dir=sys.argv[1]; size=sys.argv[2]; project=sys.argv[3]
c=json.load(sys.stdin)[0]
labels=c.get("Config",{}).get("Labels",{}) or {}
if labels.get("com.docker.compose.project") != project:
    sys.exit("ERROR: el contenedor no pertenece al proyecto Compose esperado")
tmpfs=(c.get("HostConfig",{}) or {}).get("Tmpfs",{}) or {}
if data_dir not in tmpfs:
    sys.exit("ERROR: %s no esta montado como tmpfs; abortando para no tocar disco real" % data_dir)
if size not in tmpfs[data_dir]:
    sys.exit("ERROR: tmpfs de %s no tiene size=%s (%r)" % (data_dir,size,tmpfs[data_dir]))
mounts=c.get("Mounts",[]) or []
for m in mounts:
    if m.get("Destination")==data_dir and m.get("Type")!="tmpfs":
        sys.exit("ERROR: %s no es tmpfs (Type=%s); abortando" % (data_dir,m.get("Type")))
if any("minio-data" in (m.get("Name") or "") for m in mounts):
    sys.exit("ERROR: el contenedor referencia el volumen real minio-data; abortando")
print("tmpfs ok: %s size=%s project=%s" % (data_dir,size,project))' "$DATA_DIR" "$EXPECTED_TMPFS_SIZE" "$PROJECT"
  if grep -q 'minio-data' <(dc config 2>/dev/null); then
    log "ERROR: el compose aislado menciona minio-data; abortando" >&2
    return 2
  fi
}

main() {
  log "Limpiando restos previos del proyecto $PROJECT (idempotencia)"
  dc down -v --remove-orphans >/dev/null 2>&1 || true

  log "Levantando stack aislado ($PROJECT)"
  dc up -d

  log "Esperando a MinIO, Prometheus y Alertmanager"
  local i
  for i in $(seq 1 60); do
    dc exec -T "$MINIO_SERVICE" sh -c 'curl -sf http://localhost:9000/minio/health/live >/dev/null' 2>/dev/null && break
    sleep 1
  done
  dc exec -T "$MINIO_SERVICE" sh -c 'curl -sf http://localhost:9000/minio/health/live >/dev/null' ||
    { log "ERROR: MinIO no sano" >&2; return 5; }
  wait_http "$PROM_URL/-/healthy" 90 || { log "ERROR: Prometheus no sano" >&2; return 5; }
  wait_http "$AM_URL/-/healthy" 90 || { log "ERROR: Alertmanager no sano" >&2; return 5; }
  log "Esperando el primer scrape de MinIO en Prometheus"
  wait_metric 'minio_cluster_capacity_usable_total_bytes' 90 ||
    { log "ERROR: Prometheus no scrapeo minio_cluster_capacity_usable_total_bytes" >&2; return 5; }

  verify_isolated_tmpfs | sed 's/^/  /'

  log "Llenando tmpfs a ~${FILL_HIGH_PCT:-70}%"
  local marks start end
  marks="$(wait_mib_to_pct 70 high)"
  start="${marks% *}"; end="${marks#* }"
  log "fill-70 inicio=$start fin=$end uso_tmpfs=$(tmpfs_usage)"

  local i state
  for i in $(seq 1 "$WAIT_HIGH"); do
    state="$(alert_state MinioDiskHigh)"
    if [[ "$state" == "firing" ]]; then
      log "MinioDiskHigh firing en Prometheus a las $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
    sleep 1
  done
  if [[ "$state" != "firing" ]]; then
    log "ERROR: MinioDiskHigh no llego a firing en ${WAIT_HIGH}s (estado=$state)" >&2
    log "tiempo_cruce(fill70)=$start firing=no-observado"
    return 4
  fi
  for i in $(seq 1 60); do
    if am_received MinioDiskHigh; then
      log "MinioDiskHigh recibida en Alertmanager a las $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
    sleep 1
  done
  if ! am_received MinioDiskHigh; then
    log "ERROR: Alertmanager no recibio MinioDiskHigh en 60s" >&2
    return 4
  fi

  log "Llenando tmpfs a ~85%"
  marks="$(wait_mib_to_pct 85 critical)"
  start="${marks% *}"; end="${marks#* }"
  log "fill-85 inicio=$start fin=$end uso_tmpfs=$(tmpfs_usage)"

  for i in $(seq 1 "$WAIT_CRITICAL"); do
    state="$(alert_state MinioDiskCritical)"
    if [[ "$state" == "firing" ]]; then
      log "MinioDiskCritical firing en Prometheus a las $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
    sleep 1
  done
  if [[ "$state" != "firing" ]]; then
    log "ADVERTENCIA: MinioDiskCritical no llego a firing en ${WAIT_CRITICAL}s (estado=$state); la regla exige for: 5m sobre 0.85" >&2
    log "tiempo_cruce(fill85)=$start firing=no-observado estado=$state"
    return 4
  fi
  for i in $(seq 1 60); do
    if am_received MinioDiskCritical; then
      log "MinioDiskCritical recibida en Alertmanager a las $(date -u +%Y-%m-%dT%H:%M:%SZ)"
      break
    fi
    sleep 1
  done

  log "RESULTADO: MinioDiskHigh y MinioDiskCritical dispararon y Alertmanager las recibio"
}

# FILL_HIGH_PCT solo documenta el porcentaje de la primera etapa.
FILL_HIGH_PCT=70
main
