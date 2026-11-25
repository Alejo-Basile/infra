#!/usr/bin/env bash
# Arranque de la aplicacion completa (full + sentinel) con gates de salud.
# Equivale a `qa/qa.sh up`; reenvia argumentos (--profile, --build, --dry-run).
set -Eeuo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/qa/qa.sh" up "$@"
