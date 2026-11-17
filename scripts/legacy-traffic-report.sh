#!/usr/bin/env bash
# S9-X-05: daily aggregation of legacy (v1) traffic from Traefik access logs.
#
# Reads the Traefik JSON access log, filters routers whose name starts with
# "r-inv-", classifies each request as business / technical / other per
# docs/S9/tasks/task-5.md Annex A, hashes ClientHost and User-Agent, and
# writes a sorted CSV + a JSON summary for REPORT_DATE (UTC).
#
# Exit codes:
#   0 - success
#   1 - missing / unreadable / empty log file
#   2 - no log lines for REPORT_DATE (incomplete day)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Track whether the log path was explicitly provided (env or arg); only the
# default path may fall back to reading via docker exec.
_EXPLICIT_LOG=0
if [[ -n "${LOG_FILE:-}" ]]; then _EXPLICIT_LOG=1; fi
if [[ $# -ge 1 && -n "${1:-}" ]]; then LOG_FILE="$1"; _EXPLICIT_LOG=1; fi
if [[ -z "${LOG_FILE:-}" ]]; then LOG_FILE="/var/log/traefik/access.log"; fi
OUTPUT_DIR="${OUTPUT_DIR:-${2:-${REPO_ROOT}/infra/docs/evidencias/S9/trafico-legacy}}"
REPORT_DATE="${REPORT_DATE:-${3:-$(date -u +%F)}}"

command -v jq >/dev/null 2>&1 || { echo "ERROR: jq required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 required" >&2; exit 1; }

# If the default path is unreadable, fetch the log from the container.
if [[ ! -r "${LOG_FILE}" ]]; then
    if [[ "${_EXPLICIT_LOG}" == "0" ]] && command -v docker >/dev/null 2>&1; then
        TMP_DOCKER_LOG="$(mktemp)"
        if docker exec "${TRAEFIK_CONTAINER:-infra-traefik-1}" cat /var/log/traefik/access.log > "${TMP_DOCKER_LOG}" 2>/dev/null; then
            LOG_FILE="${TMP_DOCKER_LOG}"
            trap 'rm -f "${TMP_ROWS}" "${TMP_DOCKER_LOG}"' EXIT
        else
            rm -f "${TMP_DOCKER_LOG}"
            echo "ERROR: access log not readable: ${LOG_FILE}" >&2
            exit 1
        fi
    else
        echo "ERROR: access log not readable: ${LOG_FILE}" >&2
        exit 1
    fi
fi
if [[ ! -s "${LOG_FILE}" ]]; then
    echo "ERROR: access log empty: ${LOG_FILE}" >&2
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

CSV="${OUTPUT_DIR}/${REPORT_DATE}.csv"
JSON="${OUTPUT_DIR}/${REPORT_DATE}.json"

TMP_ROWS="$(mktemp)"
trap 'rm -f "${TMP_ROWS}"' EXIT

# Filter routers with prefix r-inv-, keep only lines whose StartUTC starts
# with REPORT_DATE, normalize path (64-hex -> {hash}, UUID -> {id}).
jq -r --arg d "${REPORT_DATE}" '
  select((.RouterName // "") | startswith("r-inv-"))
  | select((.StartUTC // "") | startswith($d))
  | {
      method: (.RequestMethod // ""),
      path: (.RequestPath // ""),
      client: (.ClientHost // ""),
      ua: (."request_User-Agent" // "")
    }
  | .norm = (
      .path
      | gsub("[0-9a-fA-F]{64}"; "{hash}")
      | gsub("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"; "{id}")
    )
  | [.method, .norm, .client, .ua] | @tsv
' "${LOG_FILE}" > "${TMP_ROWS}"

if [[ ! -s "${TMP_ROWS}" ]]; then
    echo "ERROR: no log lines for ${REPORT_DATE} (incomplete day)" >&2
    exit 2
fi

python3 - "${TMP_ROWS}" "${CSV}" "${JSON}" "${REPORT_DATE}" << 'PY'
import csv
import hashlib
import json
import sys
from collections import Counter
from datetime import datetime, timezone

rows_path, csv_path, json_path, report_date = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

def classify(method, path):
    if method == "POST" and path == "/pdf/process":
        return "business"
    if method == "GET" and path == "/registros":
        return "business"
    if method == "GET" and path.startswith("/registros/hash/"):
        return "business"
    if method == "GET" and path == "/registros/{id}":
        return "business"
    if method == "PUT" and path == "/registros/{id}":
        return "business"
    if method == "DELETE" and path == "/registros/{id}":
        return "business"
    if method == "GET" and path in ("/health", "/health/ready", "/docs", "/redoc", "/openapi.json"):
        return "technical"
    return "other"

counts = Counter()
by_route = Counter()
business_total = 0
technical_total = 0

with open(rows_path) as f:
    for line in f:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t")
        if len(parts) != 4:
            continue
        method, norm, client, ua = parts
        cls = classify(method, norm)
        chash = hashlib.sha256(client.encode()).hexdigest()
        uhash = hashlib.sha256(ua.encode()).hexdigest()
        counts[(cls, method, norm, chash, uhash)] += 1
        by_route[(cls, method, norm)] += 1
        if cls == "business":
            business_total += 1
        elif cls == "technical":
            technical_total += 1

# Sorted CSV.
with open(csv_path, "w", newline="") as f:
    w = csv.writer(f)
    w.writerow(["date", "classification", "method", "path", "client_hash", "ua_hash", "count"])
    for (cls, method, norm, chash, uhash) in sorted(counts):
        w.writerow([report_date, cls, method, norm, chash, uhash, counts[(cls, method, norm, chash, uhash)]])

# JSON summary.
route_rows = []
for (cls, method, norm) in sorted(by_route):
    route_rows.append({
        "classification": cls,
        "method": method,
        "path": norm,
        "count": by_route[(cls, method, norm)],
    })

summary = {
    "date": report_date,
    "business_total": business_total,
    "technical_total": technical_total,
    "by_route": route_rows,
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
with open(json_path, "w") as f:
    json.dump(summary, f, indent=2, sort_keys=False)
    f.write("\n")
PY

exit 0
