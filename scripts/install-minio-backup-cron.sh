#!/usr/bin/env bash
# infra/scripts/install-minio-backup-cron.sh
#
# Idempotent installer for the host crontab block that runs minio-backup.sh.
# Replaces only its own delimited block; preserves all other crontab lines.

set -euo pipefail

DEST_DIR="${MINIO_BACKUP_DIR:-$HOME/minio-backups}"
MODE="exec"
SCHEDULE="17 3 * * *"
LOG_FILE=""
DRY_RUN=0
CHECK=0

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dest DIR          Destination directory (default: \$MINIO_BACKUP_DIR or \$HOME/minio-backups)
  --mode exec|docker  Backup mode (default: exec)
  --schedule "EXPR"   Cron expression, 5 fields (default: "17 3 * * *")
  --log FILE          Log file path (default: <dest>/backup.log)
  --dry-run           Print the block and resulting crontab; change nothing
  --check             Compare installed block vs desired; exit 0 if identical
  --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dest) DEST_DIR="$2"; shift 2 ;;
        --mode) MODE="$2"; shift 2 ;;
        --schedule) SCHEDULE="$2"; shift 2 ;;
        --log) LOG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --check) CHECK=1; shift ;;
        --help) usage; exit 0 ;;
        *) echo "ERROR: unknown option $1" >&2; usage >&2; exit 2 ;;
    esac
done

# Resolve the workspace root from the script path: this script lives in
# <workspace>/infra/scripts/, so the workspace root is two levels up.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Validate dest absolute.
if [[ "${DEST_DIR}" != /* ]]; then
    echo "ERROR: --dest must be an absolute path" >&2
    exit 2
fi

# Validate mode.
if [[ "${MODE}" != "exec" && "${MODE}" != "docker" ]]; then
    echo "ERROR: --mode must be exec or docker" >&2
    exit 2
fi

# Validate cron expression shape (5 fields).
if [[ "$(echo "${SCHEDULE}" | awk '{print NF}')" != "5" ]]; then
    echo "ERROR: --schedule must have exactly 5 fields" >&2
    exit 2
fi

# Reject characters that cannot be represented safely in a crontab command.
if printf '%s' "${SCHEDULE}" | grep -q '[^0-9*/, -]'; then
    echo "ERROR: --schedule contains unsupported characters" >&2
    exit 2
fi

# Default log file.
if [[ -z "${LOG_FILE}" ]]; then
    LOG_FILE="${DEST_DIR}/backup.log"
fi

# Ensure dest exists.
if [[ ! -d "${DEST_DIR}" ]]; then
    if ! mkdir -p "${DEST_DIR}" 2>/dev/null; then
        echo "ERROR: cannot create ${DEST_DIR}" >&2
        echo "Manual (requires sudo):" >&2
        echo "  sudo mkdir -p ${DEST_DIR} && sudo chown \"\$USER\" ${DEST_DIR}" >&2
        exit 1
    fi
fi

BACKUP_SCRIPT="${REPO_ROOT}/infra/scripts/minio-backup.sh"

# A crontab command is run through /bin/sh: a single quote or a newline in a
# path could split or inject a command, so both are rejected outright.
reject_unsafe_path() {
    local value="$1" name="$2"
    if [[ "${value}" == *"'"* || "${value}" == *$'\n'* ]]; then
        echo "ERROR: ${name} must not contain single quotes or newlines" >&2
        exit 2
    fi
}
reject_unsafe_path "${DEST_DIR}" "--dest"
reject_unsafe_path "${LOG_FILE}" "--log"
reject_unsafe_path "${BACKUP_SCRIPT}" "script path"

BLOCK_START="# >>> minio-backup (S9-X-01-B0) >>>"
BLOCK_END="# <<< minio-backup (S9-X-01-B0) <<<"

# Every interpolated path is single-quoted so spaces or shell metacharacters
# cannot split or inject commands in the generated crontab line.
BLOCK="${BLOCK_START}
MAILTO=\"\"
${SCHEDULE} MODE=${MODE} MINIO_BACKUP_DIR='${DEST_DIR}' '${BACKUP_SCRIPT}' >> '${LOG_FILE}' 2>&1
${BLOCK_END}"

# Read current crontab (empty if none).
CURRENT="$(crontab -l 2>/dev/null || true)"

# Build desired crontab: remove existing managed block, append new block.
# Preserve other lines byte-for-byte.
strip_block() {
    awk -v s="${BLOCK_START}" -v e="${BLOCK_END}" '
        $0==s {inb=1; next}
        $0==e {inb=0; next}
        inb==1 {next}
        {print}
    '
}

STRIPPED="$(printf '%s\n' "${CURRENT}" | strip_block)"
DESIRED="${STRIPPED}"
# trim trailing blank lines
while [[ "${DESIRED}" == *$'\n\n' ]]; do
    DESIRED="${DESIRED%$'\n'}"
done
if [[ -n "${DESIRED}" ]]; then
    DESIRED="${DESIRED}
${BLOCK}
"
else
    DESIRED="${BLOCK}
"
fi

if [[ "${CHECK}" == "1" ]]; then
    # Extract installed block
    INSTALLED_BLOCK="$(printf '%s\n' "${CURRENT}" | awk -v s="${BLOCK_START}" -v e="${BLOCK_END}" '
        $0==s {inb=1; print; next}
        $0==e {print; inb=0; next}
        inb==1 {print}
    ')"
    if [[ "${INSTALLED_BLOCK}" == "${BLOCK}" ]]; then
        echo "OK: installed block matches desired" >&2
        exit 0
    else
        echo "DRIFT: installed block differs from desired" >&2
        diff <(printf '%s\n' "${INSTALLED_BLOCK}") <(printf '%s\n' "${BLOCK}") >&2 || true
        exit 1
    fi
fi

if [[ "${DRY_RUN}" == "1" ]]; then
    echo "=== Managed block ==="
    printf '%s\n' "${BLOCK}"
    echo "=== Resulting crontab ==="
    printf '%s\n' "${DESIRED}"
    exit 0
fi

# Install (write). Only allowed via explicit run (not in this task).
printf '%s' "${DESIRED}" | crontab -
echo "installed managed block" >&2
