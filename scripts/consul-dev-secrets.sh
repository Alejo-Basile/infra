#!/usr/bin/env bash
# Dev-only bootstrap of Consul gossip key, operator token, CA + server cert.
# Idempotent: skips existing files. Never prints secret values.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SECRETS="$ROOT/secrets"
CONFIG="$ROOT/compose/consul/config"
mkdir -p "$SECRETS" "$CONFIG"
IMAGE="hashicorp/consul:1.22.7"

gen() { # gen <file> <content via stdin>
  local f="$1"
  if [[ -s "$f" ]]; then return 0; fi
  cat > "$f"
}

# gossip key
if [[ ! -s "$SECRETS/consul_gossip_key.txt" ]]; then
  docker run --rm --entrypoint consul "$IMAGE" keygen > "$SECRETS/consul_gossip_key.txt"
fi
GOSSIP="$(tr -d '\n' < "$SECRETS/consul_gossip_key.txt")"

# operator token
if [[ ! -s "$SECRETS/consul_operator_token.txt" ]]; then
  cat /proc/sys/kernel/random/uuid > "$SECRETS/consul_operator_token.txt"
fi
TOKEN="$(tr -d '\n' < "$SECRETS/consul_operator_token.txt")"

OSSL() { docker run --rm -v "$SECRETS:/w" -w /w hashicorp/consul:1.22.7 openssl "$@"; }
# CA
if [[ ! -s "$SECRETS/consul_ca_key.pem" ]]; then
  OSSL genrsa -out /w/consul_ca_key.pem 2048
fi
if [[ ! -s "$SECRETS/consul_ca_cert.pem" ]]; then
  OSSL req -x509 -new -nodes -key /w/consul_ca_key.pem -sha256 -days 825 -subj "/CN=consul-dev-ca" -out /w/consul_ca_cert.pem
fi
# server cert
if [[ ! -s "$SECRETS/consul_server_key.pem" ]]; then
  OSSL genrsa -out /w/consul_server_key.pem 2048
fi
REGEN=0
if [[ ! -s "$SECRETS/consul_server_cert.pem" ]]; then
  REGEN=1
elif ! docker run --rm -v "$SECRETS:/w" -w /w hashicorp/consul:1.22.7 openssl x509 -in /w/consul_server_cert.pem -noout -ext subjectAltName 2>/dev/null | grep -q 'consul.localhost'; then
  REGEN=1
fi
if [[ "$REGEN" == "1" ]]; then
  if [[ ! -s "$SECRETS/consul_server_key.pem" ]]; then
    OSSL genrsa -out /w/consul_server_key.pem 2048
  fi
  printf 'subjectAltName=DNS:consul,DNS:consul-agent,DNS:consul.localhost,DNS:server.dc1.consul,DNS:localhost,IP:127.0.0.1\nextendedKeyUsage=serverAuth\n' > "$SECRETS/san.cnf"
  docker run --rm -v "$SECRETS:/w" -w /w hashicorp/consul:1.22.7 sh -c 'openssl req -new -key /w/consul_server_key.pem -out /w/consul_server.csr -subj "/CN=consul" && openssl x509 -req -in /w/consul_server.csr -CA /w/consul_ca_cert.pem -CAkey /w/consul_ca_key.pem -CAcreateserial -out /w/consul_server_cert.pem -days 825 -sha256 -extfile /w/san.cnf'
  rm -f "$SECRETS/consul_server.csr" "$SECRETS/san.cnf" "$SECRETS/consul_ca_cert.srl"
fi

# generated hcl
if [[ ! -s "$CONFIG/dev-server.local.hcl" ]]; then
  cat > "$CONFIG/dev-server.local.hcl" <<EOF
# Dev-only (C04). C05 rotates/hardens gossip+TLS, C06 replaces management token.
encrypt = "$GOSSIP"
acl {
  tokens {
    initial_management = "$TOKEN"
    agent = "$TOKEN"
  }
}
EOF
fi
if [[ ! -s "$CONFIG/dev-agent.local.hcl" ]]; then
  cat > "$CONFIG/dev-agent.local.hcl" <<EOF
# Dev-only (C04). C05 rotates/hardens gossip+TLS, C06 replaces management token.
encrypt = "$GOSSIP"
acl {
  tokens {
    agent = "$TOKEN"
  }
}
EOF
fi
chmod 644 "$SECRETS"/* 2>/dev/null || true
echo "consul dev secrets ready (existing files preserved)"
