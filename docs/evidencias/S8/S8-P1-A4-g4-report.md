# S8-P1-A4 — Resultado de P1 para el informe G4

Fecha de ejecución: 2026-11-17 (04:36Z–04:44Z UTC, medición post-fix). Camino de ejecución: worktree `infra-worktrees/s8-p1-a1` (branch `feat/s8-p1-a1-replay-handoff`), merge A1.1 pendiente.

## Insumos P1

| Insumo | Estado | Referencia |
|---|---|---|
| Aislamiento (check-isolation) | PASS — `OK: aislamiento verificado` al inicio y al cierre de run 1 y run 2 | `S8-P1-A4-replay-expanded.txt` (`=== check-isolation (inicio) ===`, `=== check-isolation (run 2) ===`) |
| Entorno real sin cambios | PASS — `fingerprint-real` capturado ANTES (`04:36:07Z`) de cualquier replay y DESPUÉS de run 2 (`04:44:38Z`); `diff` vacío y mismo `sha256:777930798eecd2...5ea73aa9` | `S8-P1-A4-replay-expanded.txt` (`=== real fingerprint (before) ===`, `=== diffs ===`) |
| Fingerprints iniciales idénticos | PASS — `diff` de `start-run1.json` vs `start-run2.json` vacío (ambos `sha256:a48bb54d...479bcee`) | `S8-P1-A4-replay-expanded.txt` (`=== diffs ===`) |
| Ruteo (tabla de ruteo) | Disponible | `S8-P1-02` (commit `7ff648f`), evidencias `S8-P1-02-routing-table.txt`, `S8-P1-02-router-match.txt` |
| Pesos canary | Disponible | `S8-P1-03` (commit `396a327`), evidencia `S8-P1-03-weight-change.txt` |
| Canary 1 % | Cerrado | `S8-P1-A2`, evidencia `S8-P1-A2-canary-1pct.txt` |
| Canary 10 % | Abierto | `S8-P1-A3` (pendiente, sin cambios en esta tarea) |

## Paridad P4 (medición producida por el arnés P4; P1 solo la ejecuta y archiva)

Los artefactos del arnés P4 existen en `platform-services` (commit base `8ecb57c`, con adiciones de
fase 1 sin commitear en el worktree): manifest de corpus `tests/parity/corpus/manifest.json`
(`s8-corpus/v1`, `version s8-expanded-1`, `count 100`, `total_bytes 60900`) y runner de dos caminos
`tests/parity/replay.py` (S8-P4-02).

Se ejecutaron DOS corridas consecutivas con `reset` entre ellas sobre el entorno de replay aislado,
usando el comando del arnés P4:

```
python3 tests/parity/replay.py --manifest tests/parity/corpus/manifest.json \
  --v1-base http://localhost:9081 --v2-base http://localhost:9080 \
  --out /tmp/s8-parity-runN --threshold 99.9 --timeout 180 --id-prefix s8parrN
```

Se midió dos veces con el mismo arnés y corpus: primero con la imagen histórica
`extraction-worker:s5p1-closure` (que expuso la causa del 0,0 %) y después con la imagen corregida
`extraction-worker:s8-parity-trim`. Ambas mediciones quedan registradas:

| Medición | Imagen del worker | Corrida | run_id | docs_total | docs_compared | parity_rate | corpus_error_rate | verdicts | exit | Evidencia |
|---|---|---|---|---|---|---|---|---|---|---|
| **pre-fix** | `ghcr.io/alejo-basile/extraction-worker:s5p1-closure` | run 1 | `20261117T035355Z-65e255` | 100 | 100 | **0.0 %** | 0.0 % | MATCH 0 / MATCH_WITH_DIFF 0 / MISMATCH 100 / ERROR 0 | 1 | (histórico, ver `=== historial ===` en `S8-P1-A4-replay-expanded.txt`) |
| **pre-fix** | `ghcr.io/alejo-basile/extraction-worker:s5p1-closure` | run 2 | `20261117T040057Z-785e35` | 100 | 100 | **0.0 %** | 0.0 % | MATCH 0 / MATCH_WITH_DIFF 0 / MISMATCH 100 / ERROR 0 | 1 | (histórico) |
| **post-fix** | `extraction-worker:s8-parity-trim` | run 1 | `20261117T043656Z-83dcef` | 100 | 100 | **100.0 %** | 0.0 % | MATCH 100 / MATCH_WITH_DIFF 0 / MISMATCH 0 / ERROR 0 | 0 | `S8-P1-A4-parity-run1.json`, `S8-P1-A4-run-summary-run1.json` |
| **post-fix** | `extraction-worker:s8-parity-trim` | run 2 | `20261117T044106Z-9bc37c` | 100 | 100 | **100.0 %** | 0.0 % | MATCH 100 / MATCH_WITH_DIFF 0 / MISMATCH 0 / ERROR 0 | 0 | `S8-P1-A4-parity-run2.json`, `S8-P1-A4-run-summary-run2.json` |

Lectura directa de los umbrales en la medición post-fix: **paridad 100.0 % ≥ 99.9 % (PASA)**;
**corpus_error_rate 0.0 % < 0.1 % (PASA)**. v1 y v2 respondieron 200/COMPLETED en los 100 documentos;
no hubo errores de transporte ni de corpus. En la medición pre-fix la paridad fue 0.0 % < 99.9 %
(FALLA) con 100/100 MISMATCH y el mismo corpus_error_rate 0.0 %.

## Causa raíz y corrección aplicada

La medición pre-fix (0,0 %) se trazó a la extracción del lado v2, no al normalizador:

- El camino v2 escribe `<document_id>.md` (extensión cambiada en `P3-EXT-01`; el contenido sigue
  siendo texto plano) con la salida cruda de `pdf_extract::extract_text`, que para este corpus
  empieza con dos saltos de línea (`"\n\nPDF EXTRACTEXT ..."`).
- `platform-services/tests/parity/normalize.py` implementa `docs/paridad.md` §2 exactamente:
  colapsa secuencias de líneas vacías a una (§2.5) y recorta solo el whitespace final (§2.6). §2 no
  elimina whitespace inicial, así que el normalizador es **conforme a la especificación** y la línea
  vacía inicial sobrevivía a la normalización → `MISMATCH` en 100/100.
- La corrección vive en el adaptador de extracción, no en el normalizador:
  `extraction-worker/crates/worker/src/extract.rs`, `PdfExtractor::extract` conserva el error de
  negocio `text.trim().is_empty()` y devuelve `Ok(text.trim().to_string())` (una línea de producción).
- Cobertura: `texto_extraido_no_tiene_whitespace_de_borde` (`--lib`, sobre `tests/fixtures/minimal.pdf`)
  y `texto_extraido_no_conserva_whitespace_de_borde` (`tests/pdf_corpus.rs`, PDF de texto generado con
  `build_pdf`/`text_pdf`). Ambos fallaron antes del cambio (`"\n\nHello extraction"`,
  `"\n\nPagina 0Pagina 1"`) y pasan después.
- No se modificó `normalize.py`, `compare.py`, `report.py`, `replay.py`, los umbrales,
  `docs/paridad.md`, el compose de replay ni el stack real (`-p infra`).

## Error rate observado por P1

Solo el del entorno: healthchecks (`/healthz`, `/health`) devolvieron 200; `check-isolation` pasó al
inicio y al cierre de cada corrida; los 100 documentos v1/v2 terminaron 200/COMPLETED
(`v1_errors=0`, `v2_errors=0`). El `corpus_error_rate` medido por el arnés P4 es 0.0 %. No es un claim
de paridad ni reemplaza la medición de P4.

## Declaración explícita

La decisión Go/No-Go de G4 es de P4. P1 no emite claim de paridad ni aprueba G4.

## Gaps y bloqueadores

Solo quedan pendientes los siguientes; la paridad medida ya no es un gap abierto:

- Merge A1.1 pendiente (`infra-worktrees/s8-p1-a1` no mergeado a `infra` main).
- Firma P1 en `platform-services/docs/paridad.md` §7 (unidad P1.1) pendiente.
- Alertas de divergencia (P4, `S8-P4-04`) — sin implementación observada en `tests/parity/`.

## Contingencia

NO TRIGGERED en la medición post-fix (2026-11-17, `s8-parity-trim`): paridad 100.0 % ≥ 99.9 % y
corpus_error_rate 0.0 % < 0.1 % en dos corridas consecutivas. P1 entrega la evidencia de aislamiento
completa (fingerprints iniciales idénticos, entorno real sin cambios) y el resultado medido del
arnés. El estado `TRIGGERED` previo (medición pre-fix 0.0 %) queda registrado como historial y dejó de
aplicar tras la corrección del adaptador de extracción. La decisión sobre G4 sigue siendo de P4.

## Cambios 2026-11-17

- Se ejecutaron por primera vez las dos corridas REALES del replay P4 (S8-P4-02) sobre el corpus
  ampliado (`s8-expanded-1`, 100 PDFs) en el entorno de replay aislado, con `reset` entre corridas.
  Con la imagen `s5p1-closure` la paridad medida fue 0.0 % (100/100 MISMATCH) y la contingencia quedó
  TRIGGERED.
- Se diagnosticó la causa raíz: whitespace inicial de la salida cruda de `pdf_extract` en el artefacto
  `.md` del camino v2, que §2 de `docs/paridad.md` no elimina (el normalizador es conforme).
- Se corrigió en el adaptador de extracción (`PdfExtractor::extract` → `Ok(text.trim().to_string())`)
  con dos tests test-first, se reconstruyó la imagen `extraction-worker:s8-parity-trim`
  (`sha256:10fecc7c...d90a894b`) y se repitieron las dos corridas: paridad 100.0 %, corpus_error_rate
  0.0 %, 100/100 MATCH, exit 0 en ambas.
- Evidencia archivada: `S8-P1-A4-replay-expanded.txt` reescrito con layout §7.1 (fingerprints
  completos, salida resumida del runner, diffs y cleanup) más las secciones `=== historial ===` y el
  anexo smoke supersedido; artefactos JSON archivados byte-idénticos desde `/tmp/s8-parity-run{1,2}`:
  `S8-P1-A4-parity-run{1,2}.json` y `S8-P1-A4-run-summary-run{1,2}.json`.
- Verificación de aislamiento: `check-isolation` OK en 4 puntos; `start-run1 == start-run2`
  (diff vacío); `real before == real after` con diff vacío; 21 contenedores `infra-*` intactos.
- Las corridas smoke previas (sin replay P4) se conservan al final de `S8-P1-A4-replay-expanded.txt`
  como anexo histórico, marcadas como supersedidas y sin valor de paridad.
