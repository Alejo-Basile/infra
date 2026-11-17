#!/bin/sh
# C04 placeholder. Real CAS KV sync lands in S11-P1-C07.
set -eu
: "${KV_DIR:?}" "${SCHEMA_FILE:?}" "${CONSUL_HTTP_ADDR:?}" "${CONSUL_CACERT:?}" "${CONSUL_HTTP_TOKEN_FILE:?}"
[ -d "$KV_DIR" ] || { echo "kv dir missing"; exit 1; }
[ -f "$SCHEMA_FILE" ] || { echo "schema missing"; exit 1; }
TOKEN="$(cat "$CONSUL_HTTP_TOKEN_FILE")"
i=0
while [ "$i" -lt 60 ]; do
  leader="$(curl -s --cacert "$CONSUL_CACERT" -H "X-Consul-Token: $TOKEN" \
    "$CONSUL_HTTP_ADDR/v1/status/leader" 2>/dev/null || true)"
  if [ -n "$leader" ] && [ "$leader" != '""' ]; then
    echo "consul-kv-sync: reachability OK (C04 placeholder; KV application lands in S11-P1-C07)"
    exit 0
  fi
  i=$((i+1))
  sleep 1
done
echo "consul-kv-sync: no leader within 60s"
exit 1
