# Runbook — TTL de `documents` y reconciliador (SPEC §4)

> Quién decide qué: **el reconciliador decide el destino de un `PENDING_UPLOAD` vencido**
> (`HEAD` del objeto → `UPLOADED` o `UPLOAD_EXPIRED`); **el índice TTL de Mongo solo
> recolecta registros ya decididos**. El TTL nunca debe ser quien "decida" un expirado.

## Números reales (verificados 2026-10-05, doc-service @ 47c33c4)

| Parámetro | Valor | Origen en código |
|---|---|---|
| Ventana de subida (expira URL prefirmada `POST`) | **15 min** | `internal/api/documents.go:161` — `Expiration: 15 * time.Minute` |
| `expires_at` del documento | `created_at + 30 min` | `internal/api/documents.go:120` — `now + uploadGrace`; `Config.DocUploadGrace`, env `DOC_UPLOAD_GRACE_MIN`, **default 30 min** |
| Intervalo del reconciliador | **10 min** | `Config.ReconcileInterval`, env `RECONCILE_INTERVAL_MIN`, **default 10 min** |
| Edad mínima de seguridad (minSafetyAge) | **15 min** | `Config.MinSafetyAge`, env `MIN_SAFETY_AGE_MIN`, **default 15 min** (S6-P2-02) |
| `expireAfterSeconds` del índice TTL | **0** | `internal/adapters/mongo/migrations.go:138` — borra en `expires_at + 0` |

## Cadena de tiempo efectiva

```
created_at ──┬─ +15 min ──► vence la URL prefirmada (ventana de subida)
             └─ +30 min ──► expires_at (TTL efectivo total = 30 min + 0 s)
```

- **Gracia efectiva** (tras vencer la ventana de subida): 30 − 15 = **15 min**.
- **Regla SPEC §4**: gracia ≥ 2 × intervalo del reconciliador (10 min → 20 min).
  - La validación de `config.go:132` exige `DOC_UPLOAD_GRACE_MIN ≥ 2 × RECONCILE_INTERVAL_MIN`
    (30 ≥ 20 ✓), pero mide la gracia **desde `created_at`**, no desde el fin de la ventana.
  - Gracia estricta post-ventana: **15 min < 20 min** → tensión documentada; con el
    reconciliador actual cada 10 min y `minSafetyAge` 15 min, el documento vencido se
    evalúa ~10 min antes de que el TTL lo borre. **Margen real: 1 barrido y medio.**
    Mantener monitorizado el chequeo periódico de abajo.

## Chequeo operativo periódico

```bash
# Ejecutar con .env cargado. Esperado: 0.
docker exec infra-mongo-1 mongosh --quiet \
  -u "$MONGO_APP_USER" -p "$MONGO_APP_PASSWORD" --authenticationDatabase documents \
  documents --eval '
    const now = new Date();
    print("PENDING_UPLOAD con expires_at < now+5min:",
      db.documents.countDocuments({status:"PENDING_UPLOAD", expires_at:{$lt: new Date(now.getTime()+5*60000)}}));'
```

- **= 0** → OK.
- **> 0** → riesgo crítico activo (SPEC §4: el TTL podría borrar un documento cuyo objeto
  sí se subió antes de que el reconciliador lo evalúe) → escalar a P2 el mismo día con la
  salida de esta consulta.

## Estado de las migraciones (verificación S1-P1-11v, 2026-10-05)

`db.schema_versions.find()` está **vacío** y `getIndexes()` solo muestra `_id_`:
las migraciones de P2 (`S1-P2-05`, `internal/adapters/mongo/migrations.go` — índices
`status`, `updated_at` y TTL sobre `expires_at`) **no están aplicadas** aún en esta
instancia. Verificarlas re-ejecutando `getIndexes()` una vez que el doc-service corra
su migrador (idempotente) al arrancar. **No crear los índices a mano**: viven en las
migraciones versionadas de P2.
