#!/usr/bin/env bash
# Apagado de la aplicacion: hace `stop` y conserva volumenes y datos.
# Equivale a `qa/qa.sh down`; `--volumes` exige confirmacion explicita.
set -Eeuo pipefail
exec "$(dirname "${BASH_SOURCE[0]}")/qa/qa.sh" down "$@"
