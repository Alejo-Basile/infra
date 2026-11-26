#!/usr/bin/env bash
# down.sh — detiene el stack QA sin destruir datos (plan §4.4).
#
# Por defecto hace `stop` del perfil indicado: conserva volúmenes y datos.
# `--volumes` es destructivo y exige escribir literalmente `infra`.
# Nunca toca proyectos efímeros `qa-it-*` (los limpia test-service.sh).
set -Eeuo pipefail

QA_SCRIPT_NAME="qa/down"
# shellcheck source=lib/common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

PROFILE="full"
VOLUMES=0
FORCE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
Uso: qa.sh down [opciones]

  --profile <p>   perfil a detener (default full + sentinel + core)
  --volumes       DESTRUCTIVO: elimina contenedores y volúmenes del proyecto.
                  Exige escribir la palabra infra para confirmar.
  --force         detiene todos los perfiles (nunca omite la confirmación de --volumes)
  --dry-run       imprime lo que haría

Por defecto hace `stop`: conserva volúmenes y datos.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile)
      [[ $# -ge 2 ]] || qa_die 2 "--profile requiere un valor" "core|full|discovery|sentinel|all"
      PROFILE="$2"
      shift 2
      ;;
    --volumes) VOLUMES=1; shift ;;
    --force) FORCE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h | --help) usage; exit 0 ;;
    *) qa_die 2 "opción desconocida: $1" "qa.sh down --help" ;;
  esac
done

qa_init

# Proyectos efímeros: se listan, nunca se borran desde aquí.
stale="$(docker compose ls --format json 2>/dev/null | jq -r '.[] | select(.Name | startswith("qa-it-")) | .Name' 2>/dev/null || true)"
if [[ -n "$stale" ]]; then
  qa_log warn "proyectos de test detectados (no se tocan):"
  while IFS= read -r project; do
    printf '       docker compose -p %s down -v --remove-orphans\n' "$project"
  done <<<"$stale"
fi

PROFILE_ARGS=()
if [[ $FORCE -eq 1 || "$PROFILE" == "all" ]]; then
  for p in core full discovery sentinel chaos; do
    PROFILE_ARGS+=(--profile "$p")
  done
elif [[ "$PROFILE" == "full" ]]; then
  for p in full sentinel core; do
    PROFILE_ARGS+=(--profile "$p")
  done
else
  PROFILE_ARGS+=(--profile "$PROFILE")
fi

if [[ $VOLUMES -eq 1 ]]; then
  printf '\nADVERTENCIA: esta acción elimina contenedores y VOLÚMENES del proyecto %s.\n' "$QA_PROJECT"
  printf 'Los datos de desarrollo (Mongo, MinIO, Redis) se pierden de forma irreversible.\n'
  printf 'Comando: docker compose ... %s down -v --remove-orphans\n\n' "${PROFILE_ARGS[*]}"
  printf 'Escribe la palabra infra (en minúsculas) para confirmar: '
  read -r confirm
  if [[ "$confirm" != "infra" ]]; then
    qa_die 1 "confirmación incorrecta; no se borró nada" "si no era tu intención, no hace falta hacer nada"
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    qa_log info "[dry-run] qa_compose ${PROFILE_ARGS[*]} down -v --remove-orphans"
  else
    qa_compose "${PROFILE_ARGS[@]}" down -v --remove-orphans
    qa_log ok "proyecto $QA_PROJECT eliminado con volúmenes"
  fi
else
  if [[ $DRY_RUN -eq 1 ]]; then
    qa_log info "[dry-run] qa_compose ${PROFILE_ARGS[*]} stop"
  else
    qa_compose "${PROFILE_ARGS[@]}" stop
    qa_log ok "servicios detenidos; volúmenes y datos conservados"
  fi
fi
