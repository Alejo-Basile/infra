#!/usr/bin/env bash
# Genera certificados locales para api.localhost, s3.localhost y grafana.localhost.
# Preferencia: mkcert (CA local confiable). Fallback: openssl autofirmado.
# En produccion: ACME (Let's Encrypt staging primero).
# Uso: ./scripts/gen-certs.sh   (desde la raiz de infra/)
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/traefik/certs"
mkdir -p "$CERT_DIR"
TAG="${CONSUL_IMAGE_TAG:-1.22.7}"

if command -v mkcert >/dev/null 2>&1; then
  echo "mkcert disponible: emitiendo certificados con CA local..."
  mkcert -install || true
  mkcert -cert-file "$CERT_DIR/api.localhost.pem" -key-file "$CERT_DIR/api.localhost-key.pem" api.localhost
  mkcert -cert-file "$CERT_DIR/s3.localhost.pem"  -key-file "$CERT_DIR/s3.localhost-key.pem"  s3.localhost
  mkcert -cert-file "$CERT_DIR/grafana.localhost.pem" -key-file "$CERT_DIR/grafana.localhost-key.pem" grafana.localhost
else
  echo "mkcert no disponible: usando openssl (autofirmado)."
  echo "Los clientes deberan usar -k o confiar manualmente en los PEM."
  for host in api.localhost s3.localhost grafana.localhost; do
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$CERT_DIR/${host}-key.pem" \
      -out "$CERT_DIR/${host}.pem" \
      -subj "/CN=${host}" \
      -addext "subjectAltName=DNS:${host}" >/dev/null 2>&1
  done
fi

# Traefik corre con cap_drop ALL y no puede leer claves 600 en este entorno;
# 644 es aceptable para certificados autofirmados de desarrollo local.
# Un archivo generado dentro de un contenedor puede quedar propiedad de root:
# se devuelve la propiedad al usuario del host y luego se fijan los permisos.
chmod 644 "$CERT_DIR"/*-key.pem 2>/dev/null || true
if ls -n "$CERT_DIR"/*-key.pem | awk '{print $3}' | grep -qx 0; then
  docker run --rm -e U="$(id -u)" -e G="$(id -g)" -v "$CERT_DIR:/c" \
    hashicorp/consul:"$TAG" sh -c 'chown "$U:$G" /c/*.pem' >/dev/null 2>&1 \
    || echo "WARN: no se pudo devolver la propiedad de los certificados al usuario del host."
fi
chmod 644 "$CERT_DIR"/*-key.pem

# Consul TLS material (C05) — sign with existing Consul dev CA when available.
CA_CERT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets/consul_ca_cert.pem"
CA_KEY="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets/consul_ca_key.pem"
if [[ -s "$CA_CERT" && -s "$CA_KEY" ]]; then
  SECRETS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/secrets"
  # El contenedor escribe como root: se devuelve la propiedad al usuario del host
  # y se fija 644 para que el chmod de abajo no falle (Traefik corre con cap_drop ALL).
  docker run --rm -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$SECRETS_DIR:/s" -v "$CERT_DIR:/c" -w /s hashicorp/consul:"$TAG" sh -c 'openssl genrsa -out /c/consul.localhost-key.pem 2048 2>/dev/null && printf "subjectAltName=DNS:consul,DNS:consul-agent,DNS:consul.localhost\n" > /s/consul_san.cnf && openssl req -new -key /c/consul.localhost-key.pem -out /s/consul.csr -subj "/CN=consul" && openssl x509 -req -in /s/consul.csr -CA /s/consul_ca_cert.pem -CAkey /s/consul_ca_key.pem -CAcreateserial -out /c/consul.localhost.pem -days 825 -sha256 -extfile /s/consul_san.cnf && rm -f /s/consul.csr /s/consul_san.cnf /s/consul_ca_cert.srl && chmod 644 /c/consul.localhost.pem /c/consul.localhost-key.pem && chown "$HOST_UID:$HOST_GID" /c/consul.localhost.pem /c/consul.localhost-key.pem' >/dev/null 2>&1 || {
      echo "ERROR: no se pudo emitir el certificado de Consul (revisar CA en secrets/ y Docker)." >&2
      exit 1
    }
  echo "Consul TLS material emitted to $CERT_DIR"
else
  echo "SKIP: Consul CA not found; api/s3 generation intact."
fi

echo "Listo. Certificados en: $CERT_DIR"
echo "Verificacion: levanta el perfil full y corre  curl -kI https://api.localhost:8543/healthz"
