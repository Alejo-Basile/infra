# Matriz de Permisos MinIO (S1-P1-05a)

Las policies se aplican con nombre versionado por hash del contenido
(`<prefijo>-<sha256 corto>`) para que un entorno ya inicializado reciba el
contenido nuevo sin ventana de `AccessDenied`; ver `compose/minio/init-buckets.sh`.

| Identidad | raw-pdfs | extracted-md | extracted-txt |
|---|---|---|---|
| `SVC_DOCSERVICE` | Get, List, Head, **presign** | Get, List | Get, List |
| `SVC_WORKER` | Get **(sin Put)** | Get, Put, Delete | Get, Put, Delete |
| root | solo operación admin local, nunca en apps | — | — |

- `extracted-md` es la salida vigente (Markdown, campo `md_ref`).
- `extracted-txt` se mantiene por dos motivos hasta retirar el fallback:
  objetos `.txt` legacy que doc-service sigue sirviendo, y el worker mientras no
  aterrice su migración (T4.1 del contrato `doc-service ↔ extraction-worker`).
- El usuario de MinIO del `ocr-worker` no lo crea este bootstrap; su identidad
  vive fuera de `init-buckets.sh`.
