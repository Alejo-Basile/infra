# ADR-0022 — Contrato KV de Consul: prefijo, validación y modos de recarga

- **Estado:** Aceptado
- **Fecha:** 2026-11-17
- **Owner:** P1 (Platform / DevOps / SRE)
- **Contexto:** `docs/plan-S11-P1-consul.md` §0, §3 y §4 · `infra/docs/adr/ADR-0021-consul-registry.md`
- **Nota de numeración:** el plan original asignaba este ADR a "ADR-0020", número ya ocupado por `ADR-0020.md` (mTLS interno).

## Contexto

Ningún servicio tiene hoy cliente de configuración externa ni hot-reload: doc-service lee env una vez (`doc-service/internal/config/config.go:73`), ratelimitd construye la política al arrancar (`platform-services/rate-limiter/cmd/ratelimitd/main.go:124`), y el worker lee `ConsumerConfig::from_env()` una vez (`extraction-worker/crates/worker/src/consumer/config.rs:126`). Se quiere ajustar parámetros operativos sin rebuild, con Consul caído sin detener nada.

## Frontera (no negociable)

| Tipo de configuración | Dónde vive | NO en KV |
|---|---|---|
| Rutas y pesos del canary | `infra/traefik/dynamic/routing.yml` | NO en KV |
| Credenciales y secretos | Docker secrets | NO en KV (KV no cifra en reposo por defecto y ya existe el patrón `*_FILE`) |
| Endpoints de infraestructura (Mongo, Redis, MinIO) | compose/env | NO en KV |
| Parámetros operativos ajustables | sí, `config/<servicio>/...` | — |

## Esquema

Prefijo `config/<servicio>/<clave>`, valor crudo string, tipado y validado en el cliente. `schema.json` declara por clave `type`, `min`, `max`, `reload`, `default` y `coherence`. Coherencia se valida como conjunto (ejemplo real: `doc_upload_grace_minutes >= 2 * reconcile_interval_minutes` y `min_safety_age_minutes >= reconcile_interval_minutes`). Un valor inválido se rechaza **por clave**, se loguea con clave y motivo, incrementa `*_config_kv_rejected_total{key}`, y el valor anterior sigue vigente.

## Modos de recarga

- `hot`
- `hot-aumento` (el bulkhead usa `Semaphore::add_permits`: aumentar es seguro, reducir no recupera permisos en vuelo)
- `hot-jobs-nuevos` (`job_timeout` y `max_pages` se leen al inicio de cada trabajo)
- `restart` (`min_idle_ms` se lee una vez en el loop de XAUTOCLAIM — `runner.rs:1299` — y los `OCR_*` del crate `ocr-worker` se leen una vez en `from_env()` — `crates/ocr-worker/src/config.rs:18-63`). Cambiar el umbral del breaker no cierra un breaker `Open`.

## Clientes por módulo

Decisión: Go×2 (`doc-service/internal/configkv/` y `platform-services/rate-limiter/internal/configkv/`) porque son módulos separados sin dependencia entre sí; **Rust×1 compartido**: `crates/worker` y `crates/ocr-worker` viven en el mismo Cargo workspace (`extraction-worker/Cargo.toml:3`), así que el cliente se extrae a `crates/configkv` y lo consumen ambos. Explícito: un tercer cliente Rust copiado en el mismo workspace garantiza divergencia de validación sin ganar aislamiento. Si la extracción no cabe antes de C30, la alternativa es un cliente propio en `crates/ocr-worker/src/configkv.rs` registrado como deuda, nunca una copia sin tests de paridad. Los fixtures de C10 son compartidos por los cuatro consumidores.

## Garantías anti-dependencia

Defaults de entorno primero (arranque ≤2 s sin Consul); caché last-known-good en `/var/lib/<servicio>/config-cache.json` con escritura atómica `tmp`+`rename` y permisos `0600`; blocking queries (`?recurse&index=<idx>&wait=5m`), no polling, con backoff 1 s→30 s y jitter; registro de la revisión aplicada en `config/meta/revision`.

## Historial

Git es la auditoría: cada cambio de parámetro es un cambio de JSON versionado en `infra/compose/consul/kv/`; el audit logging nativo de Consul es Enterprise, así que no se usa como fuente de historial.

## Consecuencias

- **Positivas:** ajuste operativo sin rebuild; Consul fuera del camino crítico; contrato único verificable por fixtures.
- **Negativas/riesgo asumido:** un cliente por módulo (3 implementaciones, 4 consumidores), complejidad de los modos de recarga, y una caché en disco que exige volumen nombrado y dueño correcto bajo rootfs de solo lectura.

## Verificación

- Fixtures de `infra/compose/consul/testdata/` aceptados/rechazados igual en los cuatro consumidores.
- Dos syncs consecutivos con `changes: 0`.
- Escenario de Consul caído al arrancar con y sin caché.

## Referencias

Plan S11 §0, §1, §3, §7.10–§7.13, §7.23; ADR-0021; `infra/compose/consul/config/schema.json`; SPEC §1.3.
