#!/usr/bin/env bash
# lib/results.sh — registro de resultados de suite QA (plan §3.4).
# Sourceable; no ejecuta nada al hacer source.
# shellcheck shell=bash

if [[ -n "${_QA_RESULTS_SOURCED:-}" ]]; then
  return 0
fi
_QA_RESULTS_SOURCED=1

set -Eeuo pipefail

# Estado interno
RESULTS_SUITE="${RESULTS_SUITE:-}"
RESULTS_STARTED_AT="${RESULTS_STARTED_AT:-}"
RESULTS_START_EPOCH="${RESULTS_START_EPOCH:-0}"
declare -a _RESULTS_NAMES=()
declare -a _RESULTS_STATUSES=()
declare -a _RESULTS_DURATIONS=()
declare -a _RESULTS_REASONS=()

results_init() {
  RESULTS_SUITE="$1"
  RESULTS_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  RESULTS_START_EPOCH="$(date +%s)"
  _RESULTS_NAMES=()
  _RESULTS_STATUSES=()
  _RESULTS_DURATIONS=()
  _RESULTS_REASONS=()
}

results_record() {
  local name="$1" status="$2" duration="$3" reason="${4:-}"
  case "$status" in
    pass|fail|skip|blocked) ;;
    *) printf '[FAIL] results_record: status inválido: %s\n' "$status" >&2; return 2 ;;
  esac
  _RESULTS_NAMES+=("$name")
  _RESULTS_STATUSES+=("$status")
  _RESULTS_DURATIONS+=("$duration")
  _RESULTS_REASONS+=("$reason")
}

_xml_escape() {
  sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\\&apos;/g"
}

results_finish() {
  local dir="${1:-${QA_RUN_DIR:-/tmp/opencode/qa-results}}"
  mkdir -p "$dir"
  chmod 700 "$dir"
  local now end_epoch duration_total
  end_epoch="$(date +%s)"
  duration_total=$((end_epoch - RESULTS_START_EPOCH))
  local n=${#_RESULTS_NAMES[@]}

  # results.json con jq
  local json_checks="[]"
  local i
  for ((i=0; i<n; i++)); do
    json_checks="$(printf '%s' "$json_checks" | jq \
      --arg name "${_RESULTS_NAMES[$i]}" \
      --arg status "${_RESULTS_STATUSES[$i]}" \
      --argjson dur "${_RESULTS_DURATIONS[$i]}" \
      --arg reason "${_RESULTS_REASONS[$i]}" \
      '. + [{name:$name,status:$status,duration_s:$dur,reason:$reason}]')"
  done

  local run_id="${QA_RUN_ID:-$(date -u +%Y%m%dT%H%M%S)-$$}"
  jq -n \
    --arg run_id "$run_id" \
    --arg suite "$RESULTS_SUITE" \
    --arg started_at "$RESULTS_STARTED_AT" \
    --argjson duration_s "$duration_total" \
    --argjson checks "$json_checks" \
    '{run_id:$run_id,suite:$suite,started_at:$started_at,duration_s:$duration_s,checks:$checks}' \
    > "$dir/results.json"
  chmod 600 "$dir/results.json"

  # junit.xml
  {
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<testsuite name="%s" tests="%d" time="%d">\n' "$RESULTS_SUITE" "$n" "$duration_total"
    for ((i=0; i<n; i++)); do
      local name_esc; name_esc="$(printf '%s' "${_RESULTS_NAMES[$i]}" | _xml_escape)"
      printf '  <testcase name="%s" time="%s">\n' "$name_esc" "${_RESULTS_DURATIONS[$i]}"
      case "${_RESULTS_STATUSES[$i]}" in
        fail)
          printf '    <failure message="%s"/>\n' "$(printf '%s' "${_RESULTS_REASONS[$i]}" | _xml_escape)"
          ;;
        skip|blocked)
          printf '    <skipped/>\n'
          ;;
      esac
      printf '  </testcase>\n'
    done
    printf '</testsuite>\n'
  } > "$dir/junit.xml"
  chmod 600 "$dir/junit.xml"

  # Tabla stdout
  printf '%-32s %-8s %8s  %s\n' "CHECK" "STATUS" "DUR(s)" "REASON"
  for ((i=0; i<n; i++)); do
    printf '%-32s %-8s %8s  %s\n' "${_RESULTS_NAMES[$i]}" "${_RESULTS_STATUSES[$i]}" "${_RESULTS_DURATIONS[$i]}" "${_RESULTS_REASONS[$i]}"
  done

  # return 1 si hay fail/blocked
  local rc=0
  for ((i=0; i<n; i++)); do
    if [[ "${_RESULTS_STATUSES[$i]}" == "fail" || "${_RESULTS_STATUSES[$i]}" == "blocked" ]]; then
      rc=1
    fi
  done
  return $rc
}
