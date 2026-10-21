#!/usr/bin/env bash
# Genera certificados locales para api.localhost y s3.localhost.
# Preferencia: mkcert (CA local confiable). Fallback: openssl autofirmado.
# En produccion: ACME (Let's Encrypt staging primero).
# Uso: ./scripts/gen-certs.sh   (desde la raiz de infra/)
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/traefik/certs"
mkdir -p "$CERT_DIR"

if command -v mkcert >/dev/null 2>&1; then
  echo "mkcert disponible: emitiendo certificados con CA local..."
  mkcert -install
  mkcert -cert-file "$CERT_DIR/api.localhost.pem" -key-file "$CERT_DIR/api.localhost-key.pem" api.localhost
  mkcert -cert-file "$CERT_DIR/s3.localhost.pem"  -key-file "$CERT_DIR/s3.localhost-key.pem"  s3.localhost
else
  echo "mkcert no disponible: usando openssl (autofirmado)."
  echo "Los clientes deberan usar -k o confiar manualmente en los PEM."
  for host in api.localhost s3.localhost; do
    openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
      -keyout "$CERT_DIR/${host}-key.pem" \
      -out "$CERT_DIR/${host}.pem" \
      -subj "/CN=${host}" \
      -addext "subjectAltName=DNS:${host}" >/dev/null 2>&1
  done
fi

# Traefik corre con cap_drop ALL y no puede leer claves 600 en este entorno;
# 644 es aceptable para certificados autofirmados de desarrollo local.
chmod 644 "$CERT_DIR"/*-key.pem

echo "Listo. Certificados en: $CERT_DIR"
echo "Verificacion: levanta el perfil full y corre  curl -kI https://api.localhost:8543/healthz"
