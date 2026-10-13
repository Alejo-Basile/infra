# Matriz de Permisos MinIO (S1-P1-05a)

| Identidad | raw-pdfs | extracted-txt |
|---|---|---|
| `SVC_DOCSERVICE` | Get, List, Head, **presign** | Get, List |
| `SVC_WORKER` | Get **(sin Put)** | Get, Put, Delete |
| root | solo operación admin local, nunca en apps | — |
