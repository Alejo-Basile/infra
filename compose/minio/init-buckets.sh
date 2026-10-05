#!/bin/sh
# MinIO: buckets + identidades por servicio (minimo privilegio) — SPEC §3.4
# Idempotente: todo se crea solo si no existe.
set -e

# --- Guardarraíl: las credenciales de servicio NUNCA pueden ser las de root ---
# (criterio de seguridad no negociable n.1, pasos-iniciales.md §3.5).
# Hallado en S1: si coinciden, root ignora las policies y el test AccessDenied pasa en falso.
for pair in "SVC_DOCSERVICE_ACCESS_KEY" "SVC_WORKER_ACCESS_KEY"; do
  eval "val=\$$pair"
  if [ "$val" = "$MINIO_ROOT_USER" ]; then
    echo "ERROR: $pair es igual a MINIO_ROOT_USER. Generar credenciales distintas en .env." >&2
    exit 1
  fi
done
if [ "$SVC_DOCSERVICE_SECRET_KEY" = "$MINIO_ROOT_PASSWORD" ] || \
   [ "$SVC_WORKER_SECRET_KEY" = "$MINIO_ROOT_PASSWORD" ]; then
  echo "ERROR: un SVC_*_SECRET_KEY es igual a MINIO_ROOT_PASSWORD. Generar secretos distintos." >&2
  exit 1
fi

ALIAS="local"
mc alias set "$ALIAS" "http://minio:9000" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" --api S3v4

# --- Buckets ------------------------------------------------------------------
for bucket in raw-pdfs extracted-txt; do
  mc mb --ignore-existing "$ALIAS/$bucket"
  # Listado anonimo DESHABILITADO por defecto (ningun mc anonymous set)
done
echo "Buckets listos: raw-pdfs, extracted-txt"

# --- Policies -----------------------------------------------------------------
# doc-service: lectura de extracted-txt + presign/lectura de raw-pdfs (emite URLs)
cat > /tmp/policy-docservice.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:HeadBucket"],
      "Resource": [
        "arn:aws:s3:::raw-pdfs", "arn:aws:s3:::raw-pdfs/*",
        "arn:aws:s3:::extracted-txt", "arn:aws:s3:::extracted-txt/*"
      ]
    }
  ]
}
EOF

# worker: LEE raw-pdfs, ESCRIBE extracted-txt. JAMAS PutObject en raw-pdfs.
cat > /tmp/policy-worker.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion"],
      "Resource": ["arn:aws:s3:::raw-pdfs/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::extracted-txt/*"]
    }
  ]
}
EOF

# Policies (idempotente: "create" falla si ya existe -> se reemplaza el contenido)
mc admin policy create "$ALIAS" docservice-rw /tmp/policy-docservice.json 2>/dev/null \
  || echo "Policy docservice-rw ya existe (contenido inmutable desde S0; para cambiarla, eliminar y recrear)"
mc admin policy create "$ALIAS" worker-extract /tmp/policy-worker.json 2>/dev/null \
  || echo "Policy worker-extract ya existe"

# --- Usuarios de servicio -----------------------------------------------------
# NOTA: el fallo de `user add` se trata como idempotencia SOLO si el usuario ya existe.
# Cualquier otro error (ej. clave igual a root) aborta el script para no pasar en falso.
add_user() {
  out=$(mc admin user add "$ALIAS" "$1" "$2" 2>&1) || {
    echo "$out" | grep -qi "already exists" && echo "Usuario $1 ya existe" && return 0
    echo "ERROR creando usuario $1: $out" >&2
    return 1
  }
  echo "Usuario creado: $1"
}
add_user "$SVC_DOCSERVICE_ACCESS_KEY" "$SVC_DOCSERVICE_SECRET_KEY"
add_user "$SVC_WORKER_ACCESS_KEY" "$SVC_WORKER_SECRET_KEY"

# Attach (idempotente en mc recientes). SIN fallback deprecado `policy set`
# (imprime un ERROR "Deprecated command" pero devuelve exito, enmascarando fallos).
mc admin policy attach "$ALIAS" docservice-rw --user "$SVC_DOCSERVICE_ACCESS_KEY"
mc admin policy attach "$ALIAS" worker-extract --user "$SVC_WORKER_ACCESS_KEY"

# --- Verificacion post-init (falla ruidoso si algo no quedo) -------------------
for u in "$SVC_DOCSERVICE_ACCESS_KEY" "$SVC_WORKER_ACCESS_KEY"; do
  mc admin user info "$ALIAS" "$u" >/dev/null
  echo "Verificado: $u existe con policy adjunta."
done

echo "MinIO inicializado: buckets + politicas + usuarios de servicio."
