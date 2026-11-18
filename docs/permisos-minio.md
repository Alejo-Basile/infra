# Matriz de Permisos MinIO (S1-P1-05a)

| Identidad | raw-pdfs | extracted-txt | extracted-md |
|---|---|---|---|
| `SVC_DOCSERVICE` | Get, List, Head, **presign**, Delete | Get, List, Delete | Get, List, Delete |
| `SVC_WORKER` | Get **(sin Put)** | Get, Put, Delete | Get, Put, Delete |
| root | solo operación admin local, nunca en apps | — | — |

`extracted-md` se provisiona por el cambio a Markdown de doc-service (PR #82); el worker legacy sigue escribiendo `extracted-txt` hasta emitir `md_ref`.
