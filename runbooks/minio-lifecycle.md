# Runbook: lifecycle de MinIO (retención por bucket)

Este runbook cubre cómo reejecutar el bootstrap de MinIO, cómo inspeccionar y
cambiar las reglas de expiración, y cómo revertirlas. Las retencias vigentes son
**7 días en `raw-pdfs`** y **30 días en `extracted-txt`** (decisión de negocio en
`plan-S2-P1.md` §4; ajustables por env sin editar scripts).

Evidencia de la verificación: `docs/evidencias/S2/S1-P1-06-lifecycle.txt`
(sección T-06, ejecutada en un MinIO aislado el 2026-11-06).

## Quick path

1. Reejecutar el bootstrap (ver §1) — es idempotente.
2. Verificar las reglas (ver §2) — deben mostrar 7 y 30 días, `Enabled`.
3. Si algo salió mal, revertir una regla (ver §4).

---

## 1. Cómo reejecutar el bootstrap

Desde `infra/`:

```bash
docker compose -f compose/docker-compose.yml --profile full --env-file .env run --rm minio-init
```

- Sintaxis verificada con `docker compose -f compose/docker-compose.yml --profile full --env-file .env config --quiet` (exit 0) el 2026-11-06.
- Si MinIO ya está corriendo, no hace falta nada más; sin `--no-deps`, compose
  arrancaría `minio` si estuviera caído (ese es el comportamiento deseado en un
  bootstrap real).
- El job ejecuta `init-all.sh`, que encadena `init-buckets.sh` (buckets,
  policies, usuarios de servicio) y `lifecycle-buckets.sh` (reglas de
  expiración) con `set -e`: **si lifecycle falla, el job entero falla**.
- Salida esperada al final: `MinIO bootstrap completo: buckets + identidades + lifecycle.`
- No imprime credenciales: los secretos se resuelven con `resolve_secret`
  (`VAR_FILE` o flat) y nunca se imprimen.

## 2. Cómo inspeccionar las reglas

```bash
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  bitnamilegacy/minio-client:2025.7.21 ilm rule ls local/<bucket>
```

Repetir con `<bucket>` = `raw-pdfs` y `extracted-txt`.

| Qué esperar | raw-pdfs | extracted-txt |
| --- | --- | --- |
| `DAYS TO EXPIRE` | 7 | 30 |
| `STATUS` | `Enabled` | `Enabled` |
| Cantidad de reglas | 1 | 1 |

Estado sin reglas: `Unable to get lifecycle. The lifecycle configuration does not exist.`
(significa que el bootstrap **no** corrió o fue revertido).

Para ver el ID y los días en JSON (útil para scripts):

```bash
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  bitnamilegacy/minio-client:2025.7.21 ilm rule ls --json local/raw-pdfs
```

> `mc admin scanner status local/<bucket>` muestra el estado del scanner que
> aplica las reglas (requiere TTY: agregar `-t` a `docker run`). Sirve para
> diagnosticar, no para forzar un ciclo: este mc no tiene subcomando `start`.

## 3. Cómo cambiar la retención

Las variables `RAW_PDFS_EXPIRE_DAYS` y `EXTRACTED_TXT_EXPIRE_DAYS` están en el
servicio `minio-init` de `compose/docker-compose.yml` (con defaults 7 y 30).

1. Revertir la regla actual (§4) — si no, el paso 3 falla.
2. Cambiar el valor en `.env` (o en el `environment:` de compose).
3. Reejecutar el bootstrap (§1).
4. Verificar con `ilm rule ls` (§2).

Comportamiento ante un valor distinto del ya aplicado, verificado en T-06:

| Situación | Resultado |
| --- | --- |
| No existe regla | La crea y sale con exit 0 |
| Existe regla con los mismos días | No hace nada ("sin cambios"), exit 0 |
| Existe regla con días **distintos** | **Falla con exit 1** y el mensaje `ya tiene una regla de expiracion distinta a N dias`; no agrega una segunda regla |

Por eso, para cambiar la retención hay que **revertir primero** la regla vieja
(§4) y después reejecutar el bootstrap con el valor nuevo.

## 4. Cómo revertir una regla

```bash
docker run --rm --network infra_data --entrypoint mc \
  -e MC_HOST_local="http://${MINIO_ROOT_USER}:${MINIO_ROOT_PASSWORD}@minio:9000" \
  bitnamilegacy/minio-client:2025.7.21 ilm rule rm --id <id> local/<bucket>
```

`<id>` sale de `ilm rule ls` (§2). Después, reejecutar el bootstrap (§1) para
dejar la retención aprobada de vuelta. **No** borrar objetos a mano como parte
del rollback (ver `runbooks/minio-espacio.md` §1.3).

---

## 5. La distinción clave: expiración por edad vs. borrado tras procesamiento

Son **dos mecanismos distintos** que conviven; no los confundas al diagnosticar
un objeto que "ya no está".

### (a) Expiración por edad (lifecycle) — la red de seguridad

- Reglas: `raw-pdfs` 7 días / `extracted-txt` 30 días, aplicadas por el
  **scanner asíncrono de MinIO** por antigüedad del objeto.
- **Independiente del estado de procesamiento**: MinIO no consulta Mongo ni a la
  aplicación; borra por edad, punto.
- Es un **backstop** contra objetos huérfanos y coste de almacenamiento
  (SPEC.md L499: "Job de reconciliación (6.5) + lifecycle policies en los buckets").
- Timing: sin garantía. El scanner es de baja prioridad, corre en ciclos (~1 min
  de pausa por defecto, cubriendo ~1/16 del namespace por ciclo) y la
  documentación de MinIO avisa que puede detectar la elegibilidad **después** de
  vencer el período. Verificado en T-06: `mc admin scanner start` no existe; la
  fecha que devuelve `mc stat` en `Expiration` es la referencia confiable.

### (b) Borrado tras completar el procesamiento — el estado REAL del código

| Qué borra hoy | Dónde | Cuándo |
| --- | --- | --- |
| `.txt` huérfano en `extracted-txt` | `extraction-worker/.../pipeline.rs` (`compensate`, L257-273) y `runner.rs` (~L720) | Solo si el cierre en Mongo falla tras reintentos (compensación S2-P3-09) |
| Objeto en `raw-pdfs` sin documento en Mongo | `doc-service/internal/reconciler/reconciler.go` (`sweepOrphans`/`purgeOrphanObjects`, S4-P2-02) | Purga de huérfanos con umbral de 7 días, no "al completar" |
| Objeto en `raw-pdfs` **tras éxito** del procesamiento | **No existe** | — |

Estado real, citando SPEC.md L124-126: la fila de `raw-pdfs` dice
"Lifecycle policy: eliminar tras N días o al completar el procesamiento".
Hoy solo está implementada la parte "tras N días" (mecanismo a) más la purga de
huérfanos; **el worker no borra `raw-pdfs` después de un éxito** — solo lo lee
(GET) y escribe en `extracted-txt`. No hay un borrado por aplicación preciso
para `raw-pdfs`: no lo inventes en la documentación ni en los tickets.

### Riesgo asumido

Si la cola se atasca más de 7 días, la regla por edad puede **expirar un
`raw-pdfs` todavía no procesado**: el worker luego no puede hacer GET y ese
documento no se puede completar. La expiración por edad no distingue estados de
la SAGA; el borrado "por aplicación" (que sería preciso) hoy no existe para ese
bucket. Ante un backlog > 7 días, revisar este runbook junto con
`runbooks/minio-espacio.md` antes de tocar retenciones.

---

## Checklist

- [ ] `ilm rule ls local/raw-pdfs` muestra 7 días, `Enabled`, 1 regla
- [ ] `ilm rule ls local/extracted-txt` muestra 30 días, `Enabled`, 1 regla
- [ ] Reejecutar el bootstrap sale exit 0 y **no** cambia los IDs de regla
- [ ] Cambiar la retención implica revertir (§4) primero; si no, el job falla con exit 1
- [ ] Ningún procedimiento de este runbook toca objetos con datos reales a mano

## Referencias

- Evidencia: `docs/evidencias/S2/S1-P1-06-lifecycle.txt` (S2-P1 y T-06)
- SPEC: `docs/SPEC.md` L124-126 (retención), L499 (huérfanos + lifecycle), §6.5 (reconciliador)
- Espacio en disco y purga de huérfanos: `runbooks/minio-espacio.md`
- Rollback de compose / no borrar volúmenes: `docs/plan_pasos_finales_S5_P1.md` §10
