# Runbook: MongoDB TTL + gracia (S1-P1-11v)

## Estado verificado — 2026-11-10

MongoDB tiene los índices `_id_`, `status_1`, `updated_at_1` y `expires_at_1` (`expireAfterSeconds: 0`); existe una migración registrada. En la comprobación en vivo no había `PENDING_UPLOAD` ni documentos en riesgo a 20 o 5 minutos.

## Cálculo real

El código corregido en `doc-service` establece `expires_at = created_at + ventana_de_subida (15 min) + DOC_UPLOAD_GRACE_MIN (30 min) = 45 min`. Con `DOC_UPLOAD_GRACE_MIN=30`, `RECONCILE_INTERVAL_MIN=10` y `MIN_SAFETY_AGE_MIN=15`:

- Margen posterior al fin de la ventana: `30 min`.
- Umbral requerido por la regla `2 × intervalo`: `2 × 10 = 20 min`.
- El margen posterior cumple: `30 >= 20 min`. La validación compara la gracia posterior a la ventana con `2 × RECONCILE_INTERVAL_MIN`.

El contenedor en ejecución aún no incorpora este cálculo: hay que reconstruirlo para aplicar el fix. Hasta entonces, no asumir que el servicio vivo calcula 45 minutos.

El riesgo está latente: la consulta en vivo registró cero documentos en los rangos de riesgo. El TTL recolecta documentos vencidos; la decisión de transición corresponde al reconciliador. No crear índices manualmente: son gestionados por migraciones.

## Comprobación operativa

Ejecutar en la base `documents` para comprobar candidatos cuyo vencimiento esté a menos de 20 minutos:

```javascript
const now = new Date();
db.documents.countDocuments({
  status: "PENDING_UPLOAD",
  expires_at: { $lt: new Date(now.getTime() + 20 * 60 * 1000) }
}); // esperado: 0
```

Confirmar también los índices con `db.documents.getIndexes()` y que `schema_versions` contenga al menos una migración aplicada.

## Evidencia

- `docs/evidencias/S1/S1-P1-11-indexes.txt` — inspección histórica de índices.
- Verificación en vivo: 2026-11-10; índices TTL, `schema_versions=1`, `PENDING_UPLOAD=0`, `risk_20min=0`, `risk_5min=0`.
