# ADR-0021 — Registro y descubrimiento de servicios en Consul sin plano de tráfico

- **Estado:** Aceptado
- **Fecha:** 2026-11-17
- **Owner:** P1 (Platform / DevOps / SRE)
- **Contexto:** `docs/plan-S11-P1-consul.md` §4 y §12 · `infra/docs/adr/ADR-0022-consul-kv-contract.md` · `infra/runbooks/rollback-cutover.md`

## Contexto

El stack necesita descubrimiento real de réplicas (incluido `docker compose --scale`) y Prometheus hoy usa `dns_sd_configs` para doc-service (`infra/compose/prometheus/prometheus.yml:23-28` antes de C08) y un target estático para el worker. Consul se agrega como registro, pero el plano de tráfico ya está resuelto y es frágil: Traefik usa provider `file` con `infra/traefik/dynamic/routing.yml` como única fuente de verdad (11 routers) desde S8-P1-02, y el rollback del cutover está ensayado sobre ese archivo (`infra/runbooks/rollback-cutover.md`).

## Opciones consideradas

1. Provider `consulCatalog` en Traefik — rechazada: obliga a reescribir los 11 routers, cambia el modelo de rollback ensayado y mete a Consul en el camino crítico del tráfico.
2. `dns:` de Consul por contenedor — rechazada: rompe la resolución de nombres no registrados y acopla el arranque.
3. dnsmasq u otro proxy DNS — rechazada: componente nuevo para un problema ya resuelto.
4. Consul solo como registro y fuente para Prometheus; Traefik y DNS de Compose intactos — **elegida**.

## Decisión

- Cada réplica se registra al arrancar con `PUT /v1/agent/service/register` contra el agente local: `ID = <servicio>-<hostname>` (hostname único por réplica, incluso con `--scale`), `Name = svc-<servicio>`, `Address` = hostname del contenedor, `Port` = puerto propio, `Tags` con `http`/`s11`/`<servicio>` y `metrics_path=/metrics`, y un `Check` HTTP a `http://<hostname>:<puerto>/healthz` con `interval 10s`, `timeout 3s`, `DeregisterCriticalServiceAfter 1m`.
- Desregistro en SIGTERM/SIGINT con presupuesto de 2 s.
- Registro fallido no aborta el arranque: se loguea y suma `consul_registration_failed_total`.
- Prometheus descubre por `consul_sd_configs` con `services: [svc-doc-service, svc-extraction-worker]` y relabel de `__meta_consul_service_id` a `instance`.
- Traefik conserva provider `file`; no se agrega `consulCatalog`. Ningún contenedor recibe `dns:` de Consul.
- Servicios de infraestructura (traefik, mongo, redis, minio) se registran desde script, con checks TCP/HTTP, no desde las apps.
- `ocr-worker` (equipo P3) se registra con las mismas reglas cuando el plan §0.2 cierre: requiere `shutdown_signal` para el desregistro y `/metrics` antes de entrar a `consul_sd_configs`.

## Consecuencias

- **Positivas:** descubrimiento real con IDs por réplica; Prometheus deja de depender de DNS estático; el plano de tráfico no gana un punto de fallo.
- **Negativas/riesgo asumido:** dos fuentes de verdad distintas por diseño (Consul para registro, `routing.yml` para tráfico) y un cliente de registro por servicio.
- **Disparador de revisión:** si Consul pasa a decidir ruteo, este ADR se supersede y se reescribe el modelo de rollback.

## Verificación

- `docker compose exec consul-agent consul members -http-addr=https://127.0.0.1:8501`
- `curl` a `/api/v1/targets` de Prometheus mostrando una entrada por réplica con `instance` distinto.
- `docker compose stop <servicio>` dejando 0 entradas tras el desregistro.

## Referencias

Plan S11 §0.2, §4.1, §4.2, §7.14, §7.18; ADR-0022; `infra/traefik/traefik.yml`; `infra/runbooks/rollback-cutover.md`; SPEC §3.1 y §10.
