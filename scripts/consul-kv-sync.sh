#!/bin/sh
# S11-P1-C07: idempotent CAS sync of infra/compose/consul/kv/*.json into Consul KV.
#
# Contract (docs/S11/tasks/task-7.md §4):
#   - validates every value against schema.json BEFORE any write
#   - compares the raw value before PUT (idempotent: second run = changes: 0)
#   - CAS via ?cas=<ModifyIndex>, re-read + retry max 3 per key
#   - writes config/meta/revision (git short SHA) and config/meta/applied_at
#   - prints PASS/SKIP/FAIL per key and a final `changes: N`
#   - token only from file/env, never echoed in full
#
# Runs inside curlimages/curl (busybox sh, no jq) and on a dev host (dash/bash).
set -eu
# pipefail is not POSIX; enable it only where the shell supports it.
( set -o pipefail ) 2>/dev/null && set -o pipefail 2>/dev/null || true

usage() {
  echo "usage: $0 [--dry-run] [--kv-dir DIR] [--schema FILE]" >&2
}

DRY_RUN=0
opt_kv_dir=""
opt_schema=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --kv-dir)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      opt_kv_dir="$2"; shift 2 ;;
    --schema)
      [ "$#" -ge 2 ] || { usage; exit 2; }
      opt_schema="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

CONSUL_HTTP_ADDR="${CONSUL_HTTP_ADDR:-https://127.0.0.1:8501}"
CONSUL_KV_PREFIX="${CONSUL_KV_PREFIX:-config}"
KV_DIR="${opt_kv_dir:-${KV_DIR:-$SCRIPT_DIR/../compose/consul/kv}}"
SCHEMA_FILE="${opt_schema:-${SCHEMA_FILE:-$SCRIPT_DIR/../compose/consul/config/schema.json}}"

[ -d "$KV_DIR" ] || { echo "[FAIL] kv dir not found: $KV_DIR"; echo "changes: 0"; exit 1; }
[ -r "$SCHEMA_FILE" ] || { echo "[FAIL] schema not readable: $SCHEMA_FILE"; echo "changes: 0"; exit 1; }

# --- token: *_FILE wins over inline; never log the full value ----------------
TOKEN=""
TOKEN_FILE="${CONSUL_HTTP_TOKEN_FILE:-${CONSUL_OPERATOR_TOKEN_FILE:-}}"
if [ -n "$TOKEN_FILE" ]; then
  [ -r "$TOKEN_FILE" ] || { echo "[FAIL] token file unreadable: $TOKEN_FILE"; echo "changes: 0"; exit 1; }
  TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"
elif [ -n "${CONSUL_HTTP_TOKEN:-}" ]; then
  TOKEN="$CONSUL_HTTP_TOKEN"
else
  echo "[FAIL] no operator token: set CONSUL_HTTP_TOKEN_FILE or CONSUL_HTTP_TOKEN"
  echo "changes: 0"
  exit 1
fi
[ -n "$TOKEN" ] || { echo "[FAIL] empty operator token"; echo "changes: 0"; exit 1; }

CURL_TLS=""
if [ -n "${CONSUL_CACERT:-}" ]; then CURL_TLS="--cacert $CONSUL_CACERT"; fi

# --- revision ---------------------------------------------------------------
REVISION="${CONSUL_KV_REVISION:-}"
if [ -z "$REVISION" ] && command -v git >/dev/null 2>&1; then
  REVISION="$(git -C "$SCRIPT_DIR/../.." rev-parse --short HEAD 2>/dev/null || true)"
fi
REVISION="${REVISION:-unknown}"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/kv-sync.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT INT TERM

http_get() { # http_get <path> -> writes body to $TMP_DIR/resp, echoes status code
  # shellcheck disable=SC2086
  _c="$(curl -sS --max-time 10 $CURL_TLS \
    -H "X-Consul-Token: $TOKEN" \
    -o "$TMP_DIR/resp" -w '%{http_code}' \
    "$CONSUL_HTTP_ADDR/v1/kv/$1" 2>/dev/null)" || _c=000
  printf '%s' "${_c:-000}"
}

http_put() { # http_put <path> <cas-index> <value> -> echoes status code
  # shellcheck disable=SC2086
  _c="$(printf '%s' "$3" | curl -sS --max-time 10 $CURL_TLS \
    -H "X-Consul-Token: $TOKEN" \
    -o "$TMP_DIR/resp" -w '%{http_code}' \
    -X PUT --data-binary @- \
    "$CONSUL_HTTP_ADDR/v1/kv/$1?cas=$2" 2>/dev/null)" || _c=000
  printf '%s' "${_c:-000}"
}

# get_current <path>: sets CUR_VAL and CUR_IDX. 404 => absent, cas 0.
get_current() {
  _code="$(http_get "$1")"
  if [ "$_code" = "404" ]; then
    CUR_VAL=""
    CUR_IDX=0
    return 0
  fi
  if [ "$_code" != "200" ]; then
    CUR_VAL=""
    CUR_IDX=0
    return 1
  fi
  _b64="$(sed -n 's/.*"Value":"\([^"]*\)".*/\1/p' "$TMP_DIR/resp" | head -n 1)"
  _idx="$(sed -n 's/.*"ModifyIndex":\([0-9][0-9]*\).*/\1/p' "$TMP_DIR/resp" | head -n 1)"
  if [ -n "$_b64" ]; then
    CUR_VAL="$(printf '%s' "$_b64" | base64 -d 2>/dev/null || true)"
  else
    CUR_VAL=""
  fi
  CUR_IDX="${_idx:-0}"
  return 0
}

# --- schema: svc \t key \t type \t min \t max -------------------------------
schema_rows() {
  awk '
    /^[ \t]*"[a-z-]+": \{[ \t]*$/ {
      svc = $0
      sub(/^[ \t]*"/, "", svc)
      sub(/".*$/, "", svc)
      next
    }
    {
      if (svc == "") next
      line = $0
      if (line !~ /^[ \t]*"[A-Za-z0-9_]+"/) next
      k = line
      sub(/^[ \t]*"/, "", k)
      sub(/".*$/, "", k)
      t = ""
      if (line ~ /"type": "/) { t = line; sub(/.*"type": "/, "", t); sub(/".*$/, "", t) }
      mn = ""
      if (line ~ /"min": /) { mn = line; sub(/.*"min": /, "", mn); sub(/[,}].*$/, "", mn); sub(/[ \t]+$/, "", mn) }
      mx = ""
      if (line ~ /"max": /) { mx = line; sub(/.*"max": /, "", mx); sub(/[,}].*$/, "", mx); sub(/[ \t]+$/, "", mx) }
      print svc "\t" k "\t" t "\t" mn "\t" mx
    }
  ' "$SCHEMA_FILE"
}

# parse_flat_json <file> -> key \t value, one per line (flat map, string/number/bool)
parse_flat_json() {
  awk '
    {
      line = $0
      if (line !~ /^[ \t]*"/) next
      k = line
      sub(/^[ \t]*"/, "", k)
      sub(/".*$/, "", k)
      v = line
      sub(/^[^:]*:[ \t]*/, "", v)
      sub(/,[ \t]*$/, "", v)
      sub(/[ \t]+$/, "", v)
      if (v ~ /^".*"$/) { sub(/^"/, "", v); sub(/"$/, "", v) }
      print k "\t" v
    }
  ' "$1"
}

is_int() { case "$1" in ''|*[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# validate_value <type> <min> <max> <value> -> prints reason, returns 1 when invalid
validate_value() {
  _t="$1"; _mn="$2"; _mx="$3"; _v="$4"
  case "$_t" in
    int)
      is_int "$_v" || { echo "wrong type (expected int)"; return 1; }
      [ "$_v" -ge "$_mn" ] && [ "$_v" -le "$_mx" ] || { echo "out of range"; return 1; }
      ;;
    float)
      awk -v v="$_v" 'BEGIN { exit (v + 0 == v && v !~ /[^0-9.eE+-]/) ? 0 : 1 }' || { echo "wrong type (expected float)"; return 1; }
      awk -v v="$_v" -v mn="$_mn" -v mx="$_mx" 'BEGIN { exit (v + 0 >= mn + 0 && v + 0 <= mx + 0) ? 0 : 1 }' || { echo "out of range"; return 1; }
      ;;
    bool)
      case "$_v" in true|false) ;; *) echo "wrong type (expected bool)"; return 1 ;; esac
      ;;
    list)
      _n="$(printf '%s' "$_v" | awk -F, '{ print NF }')"
      [ "$_n" -ge "$_mn" ] && [ "$_n" -le "$_mx" ] || { echo "out of range"; return 1; }
      ;;
    *)
      echo "unknown schema type"
      return 1
      ;;
  esac
  return 0
}

# apply_key <svc> <key> <value> -> increments CHANGES/FAILS, prints one line
apply_key() {
  _svc="$1"; _key="$2"; _val="$3"
  _path="$CONSUL_KV_PREFIX/$_svc/$_key"
  _attempt=0
  while [ "$_attempt" -lt 3 ]; do
    _attempt=$((_attempt + 1))
    if ! get_current "$_path"; then
      echo "[FAIL] $_svc/$_key (http error on read)"
      FAILS=$((FAILS + 1))
      return 0
    fi
    if [ "$CUR_VAL" = "$_val" ]; then
      echo "[PASS] $_svc/$_key unchanged"
      return 0
    fi
    if [ "$DRY_RUN" = "1" ]; then
      echo "[WOULD-UPDATE] $_svc/$_key: '$CUR_VAL' -> '$_val'"
      return 0
    fi
    _code="$(http_put "$_path" "$CUR_IDX" "$_val")"
    case "$_code" in
      200)
        echo "[PASS] $_svc/$_key updated -> '$_val'"
        CHANGES=$((CHANGES + 1))
        return 0
        ;;
      409)
        continue
        ;;
      *)
        echo "[FAIL] $_svc/$_key (http $_code)"
        FAILS=$((FAILS + 1))
        return 0
        ;;
    esac
  done
  echo "[FAIL] $_svc/$_key (CAS exhausted after 3 attempts)"
  FAILS=$((FAILS + 1))
  return 0
}

CHANGES=0
FAILS=0

schema_rows > "$TMP_DIR/schema.tsv"

echo "[info] kv_dir=$KV_DIR schema=$SCHEMA_FILE addr=$CONSUL_HTTP_ADDR prefix=$CONSUL_KV_PREFIX revision=$REVISION dry_run=$DRY_RUN" >&2

for _file in "$KV_DIR"/*.json; do
  [ -f "$_file" ] || continue
  _svc="$(basename "$_file" .json)"
  parse_flat_json "$_file" > "$TMP_DIR/keys.tsv"

  # Effective set for doc-service coherence (current KV overlaid by file values).
  REJECT_COHERENCE=""
  if [ "$_svc" = "doc-service" ]; then
    _ri_f=""; _grace_f=""; _safety_f=""
    while IFS='	' read -r _k _v; do
      case "$_k" in
        reconcile_interval_minutes) _ri_f="$_v" ;;
        doc_upload_grace_minutes) _grace_f="$_v" ;;
        min_safety_age_minutes) _safety_f="$_v" ;;
      esac
    done < "$TMP_DIR/keys.tsv"
    _ri_eff="$_ri_f"; _grace_eff="$_grace_f"; _safety_eff="$_safety_f"
    for _pair in "reconcile_interval_minutes:ri" "doc_upload_grace_minutes:grace" "min_safety_age_minutes:safety"; do
      _ck="${_pair%%:*}"
      _slot="${_pair##*:}"
      [ -n "$_ck" ] || continue
      if get_current "$CONSUL_KV_PREFIX/$_svc/$_ck"; then
        if [ "$_slot" = "ri" ] && [ -z "$_ri_f" ]; then _ri_eff="$CUR_VAL"; fi
        if [ "$_slot" = "grace" ] && [ -z "$_grace_f" ]; then _grace_eff="$CUR_VAL"; fi
        if [ "$_slot" = "safety" ] && [ -z "$_safety_f" ]; then _safety_eff="$CUR_VAL"; fi
      fi
    done
    if [ -n "$_ri_eff" ] && [ -n "$_grace_eff" ]; then
      _ok="$(awk -v g="$_grace_eff" -v r="$_ri_eff" 'BEGIN { print (g + 0 >= 2 * (r + 0)) ? 1 : 0 }')"
      if [ "$_ok" != "1" ]; then
        if [ -n "$_grace_f" ]; then REJECT_COHERENCE="$REJECT_COHERENCE doc_upload_grace_minutes"; else REJECT_COHERENCE="$REJECT_COHERENCE reconcile_interval_minutes"; fi
      fi
    fi
    if [ -n "$_ri_eff" ] && [ -n "$_safety_eff" ]; then
      _ok="$(awk -v s="$_safety_eff" -v r="$_ri_eff" 'BEGIN { print (s + 0 >= r + 0) ? 1 : 0 }')"
      if [ "$_ok" != "1" ]; then
        if [ -n "$_safety_f" ]; then REJECT_COHERENCE="$REJECT_COHERENCE min_safety_age_minutes"; else REJECT_COHERENCE="$REJECT_COHERENCE reconcile_interval_minutes"; fi
      fi
    fi
  fi

  while IFS='	' read -r _key _val; do
    [ -n "$_key" ] || continue
    _row="$(awk -F'\t' -v s="$_svc" -v k="$_key" '$1 == s && $2 == k { print; exit }' "$TMP_DIR/schema.tsv")"
    if [ -z "$_row" ]; then
      echo "[SKIP] $_svc/$_key (invalid: key not declared in schema.json)"
      continue
    fi
    _typ="$(printf '%s' "$_row" | cut -f3)"
    _mn="$(printf '%s' "$_row" | cut -f4)"
    _mx="$(printf '%s' "$_row" | cut -f5)"
    _mn="${_mn:-0}"
    _mx="${_mx:-999999999}"
    if ! _reason="$(validate_value "$_typ" "$_mn" "$_mx" "$_val")"; then
      echo "[SKIP] $_svc/$_key (invalid: $_reason)"
      continue
    fi
    case " $REJECT_COHERENCE " in
      *" $_key "*)
        echo "[SKIP] $_svc/$_key (invalid: coherence doc_upload_grace_minutes >= 2 * reconcile_interval_minutes and min_safety_age_minutes >= reconcile_interval_minutes)"
        continue
        ;;
    esac
    apply_key "$_svc" "$_key" "$_val"
  done < "$TMP_DIR/keys.tsv"
done

# --- meta: revision + applied_at -------------------------------------------
# applied_at is only refreshed when a real change (or a new revision) is applied,
# so a no-op run stays `changes: 0` as task-7 §6 requires.
META_CHANGES_BEFORE="$CHANGES"

path="$CONSUL_KV_PREFIX/meta/revision"
if ! get_current "$path"; then
  echo "[FAIL] meta/revision (http error on read)"
  FAILS=$((FAILS + 1))
elif [ "$CUR_VAL" = "$REVISION" ]; then
  echo "[PASS] meta/revision unchanged"
elif [ "$DRY_RUN" = "1" ]; then
  echo "[WOULD-UPDATE] meta/revision: '$CUR_VAL' -> '$REVISION'"
else
  _attempt=0
  while [ "$_attempt" -lt 3 ]; do
    _attempt=$((_attempt + 1))
    _code="$(http_put "$path" "$CUR_IDX" "$REVISION")"
    if [ "$_code" = "200" ]; then
      echo "[PASS] meta/revision updated -> '$REVISION'"
      CHANGES=$((CHANGES + 1))
      break
    fi
    if [ "$_code" = "409" ]; then
      get_current "$path" || true
      continue
    fi
    echo "[FAIL] meta/revision (http $_code)"
    FAILS=$((FAILS + 1))
    break
  done
  if [ "$_attempt" -ge 3 ] && [ "$CUR_VAL" != "$REVISION" ]; then
    echo "[FAIL] meta/revision (CAS exhausted after 3 attempts)"
    FAILS=$((FAILS + 1))
  fi
fi

path="$CONSUL_KV_PREFIX/meta/applied_at"
APPLIED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$CHANGES" -gt "$META_CHANGES_BEFORE" ]; then
  if ! get_current "$path"; then
    echo "[FAIL] meta/applied_at (http error on read)"
    FAILS=$((FAILS + 1))
  elif [ "$DRY_RUN" = "1" ]; then
    echo "[WOULD-UPDATE] meta/applied_at: '$CUR_VAL' -> '$APPLIED_AT'"
  else
    _attempt=0
    while [ "$_attempt" -lt 3 ]; do
      _attempt=$((_attempt + 1))
      _code="$(http_put "$path" "$CUR_IDX" "$APPLIED_AT")"
      if [ "$_code" = "200" ]; then
        echo "[PASS] meta/applied_at updated -> '$APPLIED_AT'"
        CHANGES=$((CHANGES + 1))
        break
      fi
      if [ "$_code" = "409" ]; then
        get_current "$path" || true
        continue
      fi
      echo "[FAIL] meta/applied_at (http $_code)"
      FAILS=$((FAILS + 1))
      break
    done
    if [ "$_attempt" -ge 3 ] && [ "$CUR_VAL" != "$APPLIED_AT" ]; then
      echo "[FAIL] meta/applied_at (CAS exhausted after 3 attempts)"
      FAILS=$((FAILS + 1))
    fi
  fi
else
  if get_current "$path"; then
    echo "[PASS] meta/applied_at unchanged"
  else
    echo "[FAIL] meta/applied_at (http error on read)"
    FAILS=$((FAILS + 1))
  fi
fi

echo "changes: $CHANGES"
if [ "$FAILS" -gt 0 ]; then
  echo "fails: $FAILS" >&2
  exit 1
fi
exit 0
