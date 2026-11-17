#!/usr/bin/env bash
# infra/scripts/minio-backup.sh
#
# One run = one dated snapshot under $DEST_DIR/<YYYY-MM-DD>/ containing raw-pdfs/
# and extracted-txt/. A mirror never silently overwrites the only copy because each
# day gets its own directory.
#
# Usage: minio-backup.sh [DEST_DIR]
#   DEST_DIR defaults to ${MINIO_BACKUP_DIR:-/srv/backups/minio}
#
# Preview: DRY_RUN=1 prints the mc mirror commands without executing.
# Mode:    MODE=exec uses `docker exec infra-minio-1 mc ...` (fallback when the
#          minio/mc image cannot be pulled); default MODE=docker uses
#          `docker run --rm ... minio/mc`.
#
# Credentials: MINIO_ROOT_USER from infra/.env and the password from
# infra/secrets/minio_root_password.txt. Neither is ever printed or placed in
# host argv: docker mode passes MC_HOST_bk through a private 0600 --env-file
# that is removed when the script exits.
#
# Production MUST use a dedicated backup identity with read-only on raw-pdfs/
# and extracted-txt plus write on the backup target. Root is acceptable only
# for the local lab.
#
# Retention: RETENTION_DAYS (default 14) prunes dated snapshot dirs older than
#            the window after a successful backup. PRUNE_ONLY=1 runs only the
#            retention pass (no credentials, no docker, no mirror). DRY_RUN=1
#            prints prunes without deleting.

set -euo pipefail

DEST_DIR="${1:-${MINIO_BACKUP_DIR:-/srv/backups/minio}}"
# DRY_RUN-safe guard
if [[ -z "${DEST_DIR}" || "${DEST_DIR}" == "/" || "${DEST_DIR}" != /* ]]; then
    echo "ERROR: DEST_DIR must be an absolute path (not empty, /, or relative)" >&2
    exit 2
fi

DATE="$(date -u +%Y-%m-%d)"
SNAP="${DEST_DIR}/${DATE}"

PRUNE_ONLY="${PRUNE_ONLY:-0}"

# Resolve credentials without printing them (skipped in prune-only mode).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env"
SECRET_FILE="${REPO_ROOT}/secrets/minio_root_password.txt"

if [[ "${PRUNE_ONLY}" != "1" ]]; then
    if [[ ! -r "${ENV_FILE}" ]]; then
        echo "ERROR: cannot read ${ENV_FILE}" >&2
        exit 2
    fi
    if [[ ! -r "${SECRET_FILE}" ]]; then
        echo "ERROR: cannot read ${SECRET_FILE}" >&2
        exit 2
    fi
fi

if [[ "${PRUNE_ONLY}" != "1" ]]; then
    MINIO_ROOT_USER="$(grep -E '^MINIO_ROOT_USER=' "${ENV_FILE}" | head -n1 | cut -d= -f2-)"
    MINIO_ROOT_PASS="$(cat "${SECRET_FILE}")"
    MINIO_ROOT_PASS="${MINIO_ROOT_PASS%$'\n'}"

    if [[ -z "${MINIO_ROOT_USER}" || -z "${MINIO_ROOT_PASS}" ]]; then
        echo "ERROR: missing MinIO credentials" >&2
        exit 2
    fi
fi

MODE="${MODE:-docker}"
DRY_RUN="${DRY_RUN:-0}"

TMP_ENV_FILE=""
cleanup_tmp() {
    if [[ -n "${TMP_ENV_FILE}" ]]; then
        rm -f "${TMP_ENV_FILE}"
    fi
    # An EXIT trap must not override the script's own exit status.
    return 0
}
trap cleanup_tmp EXIT

RETENTION_DAYS="${RETENTION_DAYS:-14}"

# Retention pruning function.
prune_retention() {
    local cutoff
    cutoff="$(date -u -d "${RETENTION_DAYS} days ago" +%s 2>/dev/null || date -u -v-${RETENTION_DAYS}d +%s)"
    for entry in "${DEST_DIR}"/*; do
        [[ -e "${entry}" || -L "${entry}" ]] || continue
        [[ -L "${entry}" ]] && continue
        [[ -d "${entry}" ]] || continue
        local base
        base="$(basename "${entry}")"
        if [[ ! "${base}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
            continue
        fi
        local mtime
        mtime="$(stat -c %Y "${entry}" 2>/dev/null || stat -f %m "${entry}")"
        if (( mtime < cutoff )); then
            if [[ "${DRY_RUN}" == "1" ]]; then
                echo "prune: ${entry}"
            else
                echo "prune: ${entry}"
                rm -rf -- "${entry}"
            fi
        fi
    done
}

if [[ "${PRUNE_ONLY}" == "1" ]]; then
    prune_retention
    exit 0
fi

# Only the snapshot root is precreated: `docker cp <src-dir> <dest>/` copies the
# bucket directory into it, and precreating ${SNAP}/<bucket> would nest the copy.
mkdir -p "${SNAP}"

run_mirror2() {
    local bucket="$1"
    if [[ "${MODE}" == "exec" ]]; then
        if [[ "${DRY_RUN}" == "1" ]]; then
            echo "docker exec infra-minio-1 mc mirror --overwrite myminio/${bucket} /tmp/bk-${DATE}/${bucket}"
            echo "docker cp infra-minio-1:/tmp/bk-${DATE}/${bucket} ${SNAP}/"
            return 0
        fi
        docker exec infra-minio-1 sh -c "mkdir -p /tmp/bk-${DATE} && mc mirror --overwrite myminio/${bucket} /tmp/bk-${DATE}/${bucket}"
        docker cp "infra-minio-1:/tmp/bk-${DATE}/${bucket}" "${SNAP}/"
    else
        if [[ "${DRY_RUN}" == "1" ]]; then
            echo "docker run --rm --network infra_internal -v ${SNAP}:/backup --env-file <private-env> minio/mc mirror --overwrite bk/${bucket} /backup/${bucket}"
            return 0
        fi
        TMP_ENV_FILE="$(mktemp)"
        chmod 600 "${TMP_ENV_FILE}"
        printf 'MC_HOST_bk=http://%s:%s@minio:9000\n' "${MINIO_ROOT_USER}" "${MINIO_ROOT_PASS}" > "${TMP_ENV_FILE}"
        local rc=0
        docker run --rm --network infra_internal \
            -v "${SNAP}:/backup" \
            --env-file "${TMP_ENV_FILE}" \
            minio/mc mirror --overwrite "bk/${bucket}" "/backup/${bucket}" || rc=$?
        # Remove this bucket's credential file before the next bucket reuses the path.
        rm -f "${TMP_ENV_FILE}"
        TMP_ENV_FILE=""
        return "${rc}"
    fi
}

for b in raw-pdfs extracted-txt; do
    run_mirror2 "$b"
done

# object counts: a snapshot is only successful when both counts match and are
# non-empty. Retention never prunes based on an unverified snapshot.
parity_failed=0
if [[ "${DRY_RUN}" != "1" ]]; then
    for b in raw-pdfs extracted-txt; do
        src_count="$(docker exec infra-minio-1 mc ls --recursive --summarize "myminio/${b}" | awk '/Total Objects:/ {print $3}')"
        snap_count="$(find "${SNAP}/${b}" -type f | wc -l)"
        echo "${b}: source=${src_count} snapshot=${snap_count}"
        if [[ -z "${src_count}" || "${src_count}" != "${snap_count}" ]]; then
            echo "ERROR: parity mismatch for ${b}: source=${src_count:-<empty>} snapshot=${snap_count}" >&2
            parity_failed=1
        fi
    done
fi

if [[ "${parity_failed}" == "1" ]]; then
    echo "ERROR: backup incomplete, retention skipped: ${SNAP}" >&2
    exit 1
fi

# retention pruning after a verified backup
prune_retention

echo "backup complete: ${SNAP}"
