# Deuda técnica — mTLS interno no implementado (S1-P1-03)

**Decisión:** no se implementa mTLS interno en la v1; queda como deuda consciente,
registrada en `docs/adr/ADR-0020.md` (Camino B de `docs/plan-S2-P1.md` §4, S1-P1-03).

| Campo | Valor |
|---|---|
| Owner | P1 |
| Fecha de decisión | 2026-10-14 |
| Fecha de revisión | **2026-12-02** (o gate G4, lo que ocurra primero) |
| ADR | `docs/adr/ADR-0020.md` |
| Fila existente | `pasos-iniciales.md` §19.3 — "mTLS interno no implementado" |
| Cobertura mínima verificada | Red `infra_data` interna + webhook no público (404) + credenciales por bucket y rol Mongo acotado (`docs/permisos-minio.md`) |
| Evidencia | `docs/evidencias/S2/S1-P1-03-cobertura.txt` |

No queda como tarea abierta: es una decisión registrada.
