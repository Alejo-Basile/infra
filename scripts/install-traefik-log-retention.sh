#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCHEDULE="47 3 * * *"
DRY_RUN=0; CHECK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --check) CHECK=1; shift ;;
        --help) echo "Usage: $0 [--dry-run|--check]"; exit 0 ;;
        *) echo "ERROR: unknown $1" >&2; exit 2 ;;
    esac
done
BLOCK_START="# >>> traefik-log-retention (S9-X-05) >>>"
BLOCK_END="# <<< traefik-log-retention (S9-X-05) <<<"
BLOCK="${BLOCK_START}
MAILTO=\"\"
${SCHEDULE} '${REPO_ROOT}/infra/scripts/traefik-log-rotate.sh' >> \"\${HOME}/traefik-logs-archive/rotate.log\" 2>&1
${BLOCK_END}"
CURRENT="$(crontab -l 2>/dev/null || true)"
strip_block() { awk -v s="$BLOCK_START" -v e="$BLOCK_END" '$0==s{inb=1;next}$0==e{inb=0;next}inb==1{next}{print}'; }
STRIPPED="$(printf '%s\n' "$CURRENT" | strip_block)"
DESIRED="${STRIPPED}"
while [[ "${DESIRED}" == *$'\n\n' ]]; do DESIRED="${DESIRED%$'\n'}"; done
if [[ -n "${DESIRED}" ]]; then DESIRED="${DESIRED}
${BLOCK}
"; else DESIRED="${BLOCK}
"; fi
if [[ "$CHECK" == "1" ]]; then
    INSTALLED="$(printf '%s\n' "$CURRENT" | awk -v s="$BLOCK_START" -v e="$BLOCK_END" '$0==s{inb=1;print;next}$0==e{print;inb=0;next}inb==1{print}')"
    if [[ "$INSTALLED" == "$BLOCK" ]]; then echo "OK: installed block matches desired" >&2; exit 0; else echo "DRIFT" >&2; exit 1; fi
fi
if [[ "$DRY_RUN" == "1" ]]; then echo "$DESIRED"; exit 0; fi
printf '%s' "$DESIRED" | crontab -
echo "installed managed block" >&2