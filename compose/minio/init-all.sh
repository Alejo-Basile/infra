#!/bin/sh
# MinIO bootstrap idempotente: buckets + identidades + lifecycle en un solo job.
# Encadena init-buckets.sh y lifecycle-buckets.sh en el MISMO contenedor para
# compartir el alias `local` de mc y la resolucion de secretos (T-05).
# Falla si cualquiera de los dos pasos falla (set -e).
set -e

/bin/sh /init-buckets.sh
/bin/sh /lifecycle-buckets.sh

echo "MinIO bootstrap completo: buckets + identidades + lifecycle."
