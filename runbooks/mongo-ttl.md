# Runbook: MongoDB TTL + Gracia (S1-P1-11v)

## Configuración Actual

- **Colección**: `documents`
- **Índice TTL**: `expires_at_1` (TTL index, `expireAfterSeconds: 0`)
- **Campo TTL**: `expires_at` (ISODate)

## Cálculo de `expires_at`

```
expires_at = ahora + ventana_de_subida + gracia
```

Donde:
- **ventana_de_subida**: Tiempo máximo que el cliente tiene para subir el PDF (ej. 15 min)
- **gracia**: Buffer ≥ **2 × intervalo_del_reconciliador**
  - Reconciliador v1: corre cada **5–10 min**
  - → gracia mínima = **2 × 10 min = 20 min**
  - → TTL efectivo no menor a **~25–30 min** tras vencer la ventana

## Fórmula Implementada por P2 (issue #10)

```go
// En migraciones Go (internal/repository/mongo/migrations.go)
const (
    uploadWindowMinutes = 15
    graceMultiplier     = 2
    reconciliatorIntervalMinutes = 10 // configuración del job
)

expiresAt := time.Now().Add(
    time.Duration(uploadWindowMinutes + graceMultiplier*reconciliatorIntervalMinutes) * time.Minute
)
```

**Resultado**: `expires_at = ahora + 35 min` (15 + 2×10)

## Verificación de Riesgo Crítico (SPEC §4)

> "El TTL no decide el expirado: decide el reconciliador."

- El job de reconciliación corre cada 5–10 min
- Hace `HEAD` del objeto en MinIO ANTES de que el TTL borre el documento
- Si objeto existe → promociona a `UPLOADED` y limpia/extiende `expires_at`
- Si objeto NO existe → marca `UPLOAD_EXPIRED`
- **Luego** el TTL recolecta registros YA DECIDIDOS

## Chequeo: Sin Documentos con Gracia Insuficiente

```bash
# Verificar que todos los PENDING_UPLOAD tienen expires_at > ahora + 20 min
db.documents.find({
    status: "PENDING_UPLOAD",
    expires_at: { $lt: new Date(Date.now() + 20*60*1000) }
})
# Debe retornar 0 documentos
```

## Evidencia
- `docs/evidencias/S1/S1-P1-11-indexes.txt` (salida `getIndexes()` + `rs.status()` + docs PENDING_UPLOAD)
- `infra/runbooks/mongo-ttl.md` (documentado)
