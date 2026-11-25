#!/bin/sh
# MinIO: buckets + identidades por servicio (minimo privilegio) — SPEC §3.4
# Idempotente: todo se crea solo si no existe.
set -e

# --- Secret resolution: flat VAR or VAR_FILE (Docker secret) -------------------
# Usage: resolve_secret VAR_NAME
# Reads ${VAR_NAME}_FILE when set (Docker secret), otherwise keeps the flat
# variable. Fails on a missing/unreadable file or an empty value. The secret
# value is never printed.
resolve_secret() {
  _rs_var="$1"
  eval "_rs_file=\${${_rs_var}_FILE:-}"
  if [ -n "$_rs_file" ]; then
    if [ ! -r "$_rs_file" ]; then
      echo "ERROR: ${_rs_var}_FILE is missing or not readable: $_rs_file" >&2
      exit 1
    fi
    _rs_value=$(cat "$_rs_file" 2>/dev/null) || {
      echo "ERROR: ${_rs_var}_FILE could not be read: $_rs_file" >&2
      exit 1
    }
    export "${_rs_var}=${_rs_value}"
  fi
  eval "_rs_value=\${${_rs_var}:-}"
  if [ -z "$_rs_value" ]; then
    echo "ERROR: ${_rs_var} is empty (set it directly or via ${_rs_var}_FILE)" >&2
    exit 1
  fi
  unset _rs_file _rs_value
}

resolve_secret MINIO_ROOT_PASSWORD
resolve_secret SVC_DOCSERVICE_ACCESS_KEY
resolve_secret SVC_DOCSERVICE_SECRET_KEY
resolve_secret SVC_WORKER_ACCESS_KEY
resolve_secret SVC_WORKER_SECRET_KEY

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
# extracted-md es el bucket de salida vigente (artefacto Markdown, SPEC §3.4).
# extracted-txt se conserva mientras existan objetos .txt legacy: doc-service los
# sirve por el read-fallback (D5) y el worker aun escribe ahi hasta su migracion.
for bucket in raw-pdfs extracted-md extracted-txt; do
  mc mb --ignore-existing "$ALIAS/$bucket"
  # Listado anonimo DESHABILITADO por defecto (ningun mc anonymous set)
done
echo "Buckets listos: raw-pdfs, extracted-md, extracted-txt"

# --- Policies -----------------------------------------------------------------
# doc-service: emite URLs presignadas POST de subida a raw-pdfs (ESCRIBE via
# POST policy) y lee los buckets de salida: extracted-md (vigente) y
# extracted-txt (fallback legacy). Requiere s3:PutObject en raw-pdfs, si no
# MinIO rechaza la subida prefirmada con AccessDenied (E2E-01 paso 4).
cat > /tmp/policy-docservice.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:GetObjectVersion", "s3:ListBucket", "s3:HeadBucket"],
      "Resource": [
        "arn:aws:s3:::raw-pdfs", "arn:aws:s3:::raw-pdfs/*",
        "arn:aws:s3:::extracted-md", "arn:aws:s3:::extracted-md/*",
        "arn:aws:s3:::extracted-txt", "arn:aws:s3:::extracted-txt/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject"],
      "Resource": ["arn:aws:s3:::raw-pdfs/*"]
    }
  ]
}
EOF

# worker: LEE raw-pdfs, ESCRIBE el artefacto extraido. JAMAS PutObject en raw-pdfs.
# extracted-md es el destino vigente; extracted-txt queda como transicion hasta
# que el repo extraction-worker migre (T4.1 del contrato doc-service↔worker).
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
      "Resource": ["arn:aws:s3:::extracted-md/*"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": ["arn:aws:s3:::extracted-txt/*"]
    }
  ]
}
EOF

# --- Policies: aplicacion convergente ----------------------------------------
# Por que no `mc admin policy create || echo "ya existe"`: `create` falla si la
# policy existe y NO actualiza su contenido, asi que un entorno ya inicializado
# se quedaba con la policy vieja (sin extracted-md) en silencio.
# Por que no `remove` + `create`: `mc admin policy remove` falla si la policy
# esta adjunta ("cannot be removed, as it is in use") y desadjuntar primero abre
# una ventana de AccessDenied.
# Secuencia usada: nombre versionado por hash del contenido -> crear el nuevo ->
# adjuntar (union de permisos, sin ventana) -> desadjuntar y borrar los viejos
# del mismo prefijo.
policy_name_for() {
  _pn_prefix="$1"
  _pn_hash=$(sha256sum "$2" | cut -c1-8)
  if [ -z "$_pn_hash" ]; then
    echo "ERROR: no se pudo calcular el hash de $_pn_prefix ($2)." >&2
    exit 1
  fi
  echo "${_pn_prefix}-${_pn_hash}"
}

# Reintento acotado. Uso: retry <intentos> <comando...>
# En un MinIO recien creado los usuarios y las policies tardan en ser visibles
# para la API de asociacion: `mc admin user add` responde OK y el `attach`
# inmediato falla con "The specified user does not exist" / "canned policy does
# not exist". Con el MinIO ya asentado (stack de desarrollo) no ocurre, por eso
# el fallo solo aparece en entornos efimeros.
retry() {
  _r_tries="$1"
  shift
  _r_n=1
  while [ "$_r_n" -le "$_r_tries" ]; do
    if "$@"; then
      unset _r_tries _r_n
      return 0
    fi
    _r_n=$((_r_n + 1))
    sleep 1
  done
  unset _r_tries _r_n
  return 1
}

converge_policy() {
  _cp_prefix="$1"
  _cp_user="$2"
  _cp_file="$3"
  _cp_name=$(policy_name_for "$_cp_prefix" "$_cp_file")

  if ! mc admin policy info "$ALIAS" "$_cp_name" >/dev/null 2>&1; then
    retry 10 mc admin policy create "$ALIAS" "$_cp_name" "$_cp_file" >/dev/null || {
      echo "ERROR: no se pudo crear la policy $_cp_name." >&2
      exit 1
    }
    echo "Policy creada: $_cp_name"
  fi

  if ! retry 15 mc admin policy attach "$ALIAS" "$_cp_name" --user "$_cp_user" >/dev/null 2>&1; then
    echo "ERROR: no se pudo adjuntar $_cp_name a $_cp_user." >&2
    mc admin policy attach "$ALIAS" "$_cp_name" --user "$_cp_user" >/dev/null
    exit 1
  fi

  for _cp_old in $(mc admin policy list "$ALIAS" --json \
    | jq -r 'select(.status == "success") | .policy'); do
    case "$_cp_old" in
      "$_cp_prefix" | "$_cp_prefix"-*) ;;
      *) continue ;;
    esac
    [ "$_cp_old" = "$_cp_name" ] && continue
    mc admin policy detach "$ALIAS" "$_cp_old" --user "$_cp_user" >/dev/null 2>&1 || true
    mc admin policy remove "$ALIAS" "$_cp_old" >/dev/null 2>&1 || true
    echo "Policy retirada: $_cp_old (reemplazada por $_cp_name)"
  done

  unset _cp_prefix _cp_user _cp_file _cp_name _cp_old
}

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

converge_policy docservice-rw "$SVC_DOCSERVICE_ACCESS_KEY" /tmp/policy-docservice.json
converge_policy worker-extract "$SVC_WORKER_ACCESS_KEY" /tmp/policy-worker.json

# --- Verificacion post-init (falla ruidoso si algo no quedo) -------------------
verify_policy() {
  _vp_prefix="$1"
  _vp_user="$2"
  _vp_file="$3"
  shift 3
  _vp_expected=$(policy_name_for "$_vp_prefix" "$_vp_file")
  # La asociacion tarda en reflejarse: se reintenta la lectura antes de fallar.
  _vp_attached=""
  for _vp_n in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    _vp_attached=$(mc admin user info "$ALIAS" "$_vp_user" --json | jq -r '.policyName')
    [ "$_vp_attached" = "$_vp_expected" ] && break
    sleep 1
  done
  if [ "$_vp_attached" != "$_vp_expected" ]; then
    echo "ERROR: el usuario $_vp_user tiene '$_vp_attached', se esperaba '$_vp_expected'." >&2
    exit 1
  fi
  # El cambio .txt -> .md depende de que la policy cubra extracted-md: si el
  # JSON se edito mal, el fallo debe aparecer aca y no como AccessDenied en runtime.
  # Se exigen ARN exactos (no subcadena): `grep` de 'extracted-md' aceptaria solo
  # `extracted-md/*` y daria por buena una policy incompleta. Los ARN requeridos
  # dependen de la policy: solo doc-service lista/head el bucket (ARN sin `/*`).
  _vp_resources=$(mc admin policy info "$ALIAS" "$_vp_expected" --json \
    | jq -r '.policyInfo.Policy.Statement[].Resource[]' 2>/dev/null || true)
  for _vp_arn in "$@"; do
    if ! printf '%s\n' "$_vp_resources" | grep -Fxq "$_vp_arn"; then
      echo "ERROR: la policy $_vp_expected no incluye $_vp_arn." >&2
      exit 1
    fi
  done
  echo "Verificado: $_vp_user con policy $_vp_expected (incluye extracted-md)."
  unset _vp_prefix _vp_user _vp_file _vp_expected _vp_attached _vp_resources _vp_arn _vp_n
}

verify_policy docservice-rw "$SVC_DOCSERVICE_ACCESS_KEY" /tmp/policy-docservice.json \
  "arn:aws:s3:::extracted-md" "arn:aws:s3:::extracted-md/*"
verify_policy worker-extract "$SVC_WORKER_ACCESS_KEY" /tmp/policy-worker.json \
  "arn:aws:s3:::extracted-md/*"

echo "MinIO inicializado: buckets + politicas + usuarios de servicio."
