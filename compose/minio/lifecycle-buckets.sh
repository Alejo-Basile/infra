#!/bin/sh
# MinIO: lifecycle (retencion) por bucket — plan-S2-P1.md §4 (S1-P1-06)
# Separado de init-buckets.sh a proposito: identidades != politica de datos.
# Idempotente: si ya existe una regla con la misma expiracion, NO la vuelve a agregar
# (agregarla a ciegas crea reglas duplicadas en el bucket).
set -e

ALIAS="local"

# Valores de retencion configurables por entorno; los defaults son la decision
# registrada en §4 (raw-pdfs 7 dias, extracted-txt 30 dias — retencion de negocio,
# ajustable sin tocar el script).
RAW_PDFS_EXPIRE_DAYS="${RAW_PDFS_EXPIRE_DAYS:-7}"
EXTRACTED_TXT_EXPIRE_DAYS="${EXTRACTED_TXT_EXPIRE_DAYS:-30}"

# ¿Ya existe una regla con esta expiracion en el bucket?
# `ilm rule ls --json` falla con "NoSuchLifecycleConfiguration" cuando el bucket no
# tiene ninguna configuracion; ese caso NO es error aca, significa "todavia no existe".
rule_has_days() {
  bucket=$1
  days=$2
  mc ilm rule ls --json "$ALIAS/$bucket" 2>/dev/null \
    | grep -Eq "\"Days\":[[:space:]]*${days}([^0-9]|$)"
}

apply_rule() {
  bucket=$1
  days=$2
  if rule_has_days "$bucket" "$days"; then
    echo "Lifecycle ya presente: $ALIAS/$bucket expira a los ${days} dias (sin cambios)."
  else
    # --prefix "" aplica la regla a todo el bucket (sin filtro de prefijo).
    mc ilm rule add --expire-days "$days" --prefix "" "$ALIAS/$bucket"
    echo "Lifecycle agregado: $ALIAS/$bucket expira a los ${days} dias."
  fi
}

apply_rule raw-pdfs "$RAW_PDFS_EXPIRE_DAYS"
apply_rule extracted-txt "$EXTRACTED_TXT_EXPIRE_DAYS"

# --- Verificacion post-aplicacion (falla ruidoso si algo no quedo) -------------
echo "--- Reglas activas ---"
for bucket in raw-pdfs extracted-txt; do
  echo "== $ALIAS/$bucket =="
  mc ilm rule ls "$ALIAS/$bucket"
done

for pair in "raw-pdfs:$RAW_PDFS_EXPIRE_DAYS" "extracted-txt:$EXTRACTED_TXT_EXPIRE_DAYS"; do
  b=${pair%%:*}
  d=${pair##*:}
  rule_has_days "$b" "$d" \
    || { echo "ERROR: $b quedo sin regla de ${d} dias." >&2; exit 1; }
done
echo "Lifecycle aplicado y verificado: raw-pdfs=${RAW_PDFS_EXPIRE_DAYS}d, extracted-txt=${EXTRACTED_TXT_EXPIRE_DAYS}d."
