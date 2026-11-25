#!/usr/bin/env bash
# qa.sh — despachador único de la automatización QA (plan §3).
#
#   qa.sh up [opciones]      ciclo de vida del entorno (perfil core/full/...)
#   qa.sh status [--json]    estado de solo lectura
#   qa.sh down [opciones]    stop seguro (nunca down -v sin confirmación)
#   qa.sh test <destino>     lint/unit/integration por microservicio
#   qa.sh e2e [suites]       suites de punta a punta
#   qa.sh doctor             diagnóstico del entorno (solo lectura)
#
# Códigos de salida: 0 ok, 1 falla de test, 2 preflight/workspace,
# 3 configuración/secretos/certs, 4 timeout, 5 dependencia externa.
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
  test      Pruebas por servicio: doc-service | extraction-worker |
            ocr-worker | platform-services | infra | all
            Opciones: --lint --unit --integration --all --no-deps
                      --keep-deps --timeout <s> --json
  e2e       Suites de punta a punta. Opciones: --runs <n> --slow --keep-stack
            --keep-data --fail-fast --timeout <s> --list --json --dry-run
  doctor    Diagnóstico de herramientas, .env, secretos, certs y compose.

Variables: QA_PROJECT, QA_PORT_BASE, QA_RUN_ID, QA_ARTIFACTS_DIR,
           QA_TIMEOUT_UNIT, QA_TIMEOUT_INTEGRATION, QA_TIMEOUT_E2E,
           QA_KEEP_DEPS, QA_KEEP_STACK, QA_KEEP_DATA, QA_LOG_LEVEL.
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
    up | status | down | e2e)
      shift
      local script="$QA_SCRIPTS_DIR/${cmd}.sh"
      [[ -f "$script" ]] || qa_die 2 "script no encontrado: $script" "reinstala infra/scripts/qa/"
      exec bash "$script" "$@"
      ;;
    test)
      shift
      local script="$QA_SCRIPTS_DIR/test-service.sh"
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
