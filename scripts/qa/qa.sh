#!/usr/bin/env bash
# qa.sh — despachador único de la automatización QA (plan §3).
#
#   qa.sh up [opciones]      ciclo de vida del entorno (perfil core/full/...)
#   qa.sh status [--json]    estado de solo lectura
#   qa.sh down [opciones]    stop seguro (nunca down -v sin confirmación)
#   qa.sh doctor             diagnóstico del entorno (solo lectura)
#
# Códigos de salida: 0 ok, 2 preflight/workspace, 3 configuración/secretos/certs,
# 4 timeout, 5 dependencia externa.
set -Eeuo pipefail

QA_SCRIPT_NAME="qa"
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<'EOF'
Uso: qa.sh <comando> [opciones]

Comandos:
  up        Levanta el entorno (perfil core|full|discovery|sentinel|all).
            Opciones: --profile <p> --build --init-secrets --no-init
                      --timeout <s> --no-wait --dry-run
  status    Muestra el estado real del stack. Opciones: --json
  down      Detiene servicios sin borrar datos. Opciones: --profile <p>
            --volumes (exige confirmación) --dry-run
  doctor    Diagnóstico de herramientas, .env, secretos, certs y compose.

Variables: QA_PROJECT, QA_RUN_ID, QA_ARTIFACTS_DIR, QA_LOG_LEVEL.
EOF
}

main() {
  local cmd="${1:-}"
  case "$cmd" in
    "" | -h | --help | help)
      usage
      [[ -n "$cmd" ]] && return 0
      return 2
      ;;
    up | status | down)
      shift
      local script="$QA_SCRIPTS_DIR/${cmd}.sh"
      [[ -f "$script" ]] || qa_die 2 "script no encontrado: $script" "reinstala infra/scripts/qa/"
      exec bash "$script" "$@"
      ;;
    doctor)
      shift
      qa_doctor "$@"
      ;;
    *)
      printf '[FAIL] qa · comando desconocido: %s\n\n' "$cmd" >&2
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
