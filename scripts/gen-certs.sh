#!/usr/bin/env bash
# Genera certificados locales confiables con mkcert — variante local de S0-P1-07
# En produccion: ACME (Let's Encrypt staging primero). Aqui: mkcert.
# Uso: ./scripts/gen-certs.sh   (desde la raiz de infra/)
set -euo pipefail

CERT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/traefik/certs"
mkdir -p "$CERT_DIR"

command -v mkcert >/dev/null 2>&1 || {
  echo "mkcert no instalado. Ejecuta ./scripts/bootstrap.sh y sigue la pista de instalacion."
  exit 1
}

echo "Instalando la CA local de mkcert (un paso por maquina)..."
mkcert -install

echo "Emitiendo certificados..."
mkcert -cert-file "$CERT_DIR/api.localhost.pem" -key-file "$CERT_DIR/api.localhost-key.pem" api.localhost
mkcert -cert-file "$CERT_DIR/s3.localhost.pem"  -key-file "$CERT_DIR/s3.localhost-key.pem"  s3.localhost

chmod 644  # el contenedor corre cap_drop ALL: la key debe ser legible por el usuario de Traefik (solo dev local) "$CERT_DIR"/*-key.pem

echo "Listo. Certificados en: $CERT_DIR"
echo "Verificacion: levanta el perfil full y corre  curl -I https://api.localhost  (sin -k)"
