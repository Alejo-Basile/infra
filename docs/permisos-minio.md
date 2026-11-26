# Matriz de Permisos MinIO (S1-P1-05a)

| Identidad | raw-pdfs | extracted-txt | extracted-md |
|---|---|---|---|
| `SVC_DOCSERVICE` | Get, List, Head, **presign**, Delete | Get, List, Delete | Get, List, Delete |
| `SVC_WORKER` | Get **(sin Put)** | Get, Put, Delete | Get, Put, Delete |
| root | solo operación admin local, nunca en apps | — | — |

`extracted-md` se provisiona por el cambio a Markdown de doc-service (PR #82); el worker legacy sigue escribiendo `extracted-txt` hasta emitir `md_ref`.

Las policies se aplican con **nombre versionado por hash del contenido**
(`docservice-rw-<sha256 corto>` / `worker-extract-<sha256 corto>`): el nombre
nuevo se crea y se adjunta antes de retirar el viejo, de modo que un entorno ya
inicializado recibe el contenido nuevo sin ventana de `AccessDenied` ni perdida
de permisos si el `create` falla. Ver `compose/minio/init-buckets.sh`.

Retencion de objetos: `extracted-md` y `extracted-txt` expiran a los 30 dias
(`EXTRACTED_MD_EXPIRE_DAYS` / `EXTRACTED_TXT_EXPIRE_DAYS`); `raw-pdfs` a los 7.
Ver `runbooks/minio-lifecycle.md`.
