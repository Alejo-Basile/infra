# Matriz de permisos — MinIO (mínimo privilegio)

> **Fuente de verdad ejecutable:** `compose/minio/init-buckets.sh` (policies `docservice-rw` y
> `worker-extract`). Este documento es la vista legible para revisión y auditoría.
> Referencia: SPEC.md §3.4, §9 · `pasos-iniciales.md` §3.5 (nunca root en aplicaciones).

| Identidad | raw-pdfs | extracted-txt | Notas |
|---|---|---|---|
| `SVC_DOCSERVICE` | `GetObject`, `GetObjectVersion`, `ListBucket`, `HeadBucket` + **emisión de URLs prefirmadas** | `GetObject`, `GetObjectVersion`, `ListBucket`, `HeadBucket` | Emite el `POST` prefirmado (policy con `content-length-range`); nunca recibe el binario |
| `SVC_WORKER` | `GetObject`, `GetObjectVersion` (**sin `PutObject`**) | `GetObject`, `PutObject`, `DeleteObject` | Lee el PDF original; escribe/borra el `.txt` (el `DeleteObject` es para la compensación de la SAGA) |
| root (`MINIO_ROOT_*`) | admin | admin | **Solo operación local (init/mc). NUNCA en una aplicación** |
| anónimo | nada (listado deshabilitado) | nada | Sin `mc anonymous set` |

## Reglas

1. Ninguna aplicación usa `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` — `init-buckets.sh` aborta
   si alguna `SVC_*` coincide con root (fail-fast, hallado en S1).
2. Cambiar una policy = editar `init-buckets.sh` → eliminar la policy (`mc admin policy
   remove`) → reejecutar `minio-init`. Las policies existentes no se modifican en caliente.
3. Verificación periódica (DoD de `S1-P1-05`):
   - `mc admin policy info local <policy>` coincide con esta tabla.
   - `cp` del worker a `raw-pdfs` → `AccessDenied`.
   - `ls` anónimo a cualquier bucket → `AccessDenied`.
4. La URL base de firma del doc-service sale de `MINIO_PUBLIC_ENDPOINT` (ADR-0016), nunca
   de un literal en código.
