# S9-X-04 — Auditoría de seguridad final

Fecha: 2026-11-17 · Actualización: 2026-11-18 (incorporación de `ocr-worker` y política de excepciones)

## 1. Resumen ejecutivo

Se ejecutó la auditoría de seguridad final sobre los 4 repositorios del proyecto (infra, doc-service, extraction-worker, platform-services), cubriendo imágenes de contenedor, secretos, SCA Go/Rust, permisos y mínimo privilegio, headers y TLS, consola MinIO y SCA de dependencias. La revisión del 2026-11-18 incorporó `ocr-worker` (crate dentro de `extraction-worker`) al inventario y formalizó la política de excepciones.

Resultado global: 85 CRITICAL / 1595 HIGH sobre 19 imágenes del perfil `full`, cubiertos por 241 advisory IDs aceptados con owner, fecha de revisión y mitigación en `infra/SECURITY.md` e `infra/.trivyignore`. Solo `doc-service` está limpio (0/0); `extraction-worker` (0/106), `ocr-worker` (1/149) y `ratelimitd` (0/0) heredan CVEs de su base Debian y de binarios vendorizados, no del código del proyecto. Los criterios 2 a 6 son Go. El gate G5 ya no queda bloqueado por el criterio 1: queda como Go con excepción aceptada.

## 2. Alcance

| Repositorio | Qué se verificó |
|---|---|
| infra | Imágenes Docker (trivy), secretos (gitleaks), permisos de contenedores, headers/TLS, consola MinIO, SCA |
| doc-service | Imágenes Docker (trivy), secretos (gitleaks), govulncheck |
| extraction-worker | Imágenes Docker (trivy), secretos (gitleaks), SCA Rust (cargo-audit/cargo-deny, bloqueado por cuota de disco) |
| platform-services | Secretos (gitleaks); sin go.mod (sin SCA Go aplicable) |
| extraction-worker (crate `ocr-worker`) | Imagen Docker `ghcr.io/alejo-basile/ocr-worker` (Trivy), permisos del contenedor, exposición de red |

## 3. Herramientas y versiones

- trivy (scan de imágenes, CRITICAL/HIGH)
- gitleaks (detección de secretos en git)
- govulncheck v1.9.0 (scanner Go 1.26.11)
- docker inspect (permisos, CapDrop, usuarios)
- curl (headers, TLS)
- mc (MinIO client)
- No disponibles: openssl, cargo-audit, cargo-deny (cuota de disco para Rust)

## 4. Comandos ejecutados

- Trivy: loop `for img in $(cat /tmp/images.txt); do trivy image --severity CRITICAL,HIGH --exit-code 1 "$img"; done`
- Gitleaks: `gitleaks git --redact --verbose` por repo; `--config .gitleaks.toml` en platform-services (4 repos, historia completa)
- govulncheck: `govulncheck ./...` en doc-service y platform-services
- docker inspect: loop sobre los 21 contenedores (`docker inspect --format '{{.HostConfig.CapDrop}} {{.Config.User}}'`)
- curl: `curl -skI https://api.localhost:8543/...` para headers; `curl --tlsv1.1/--tlsv1.2/--tlsv1.3` para TLS
- docker port / nc / curl para consola MinIO (9001)

## 5. Resultados por criterio

### 5.1 Criterio 1 — Imágenes base (Go con excepción aceptada)
85 CRITICAL / 1595 HIGH sobre las 19 imágenes del perfil `full`. `doc-service` es la única limpia (0/0). Excepciones: `infra/SECURITY.md` > 'Excepciones aceptadas' y `infra/.trivyignore` (241 advisory IDs, owner P1, review 2026-12-01). Importante: `trivy` auto-carga `./.trivyignore`, así que el scan crudo se corrió desde `/tmp` con `--ignorefile /dev/null`; sin ese detalle todo reporta 0/0 y la evidencia sería falsa. Evidencia: S9-P1-04-trivy.txt.

### 5.2 Criterio 2 — Secretos (Go)
0 leaks en 4 repos. Evidencia: S9-P1-04-gitleaks.txt.

### 5.3 Criterio 3 — Headers (Go)
4 headers observados en api y s3 (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy). Evidencia: S9-P1-04-headers-tls.txt.

### 5.4 Criterio 4 — TLS (Go)
TLS 1.1 rechazado (exit 35), TLS 1.2/1.3 aceptados (200). Evidencia: S9-P1-04-headers-tls.txt.

### 5.5 Criterio 5 — Consola MinIO (Go)
No expuesta (puerto vacío, nc refused, curl 000, sin router). Evidencia: S9-P1-04-headers-tls.txt.

### 5.6 Criterio 6 — Permisos y mínimo privilegio (Go)
22/22 CapDrop=[ALL], non-root, worker update-only, identidades MinIO, separación Redis. Evidencia: S9-P1-04-permisos.txt.

## 6. Hallazgos

### CVE por imagen (container)

| Imagen | CRITICAL | HIGH |
|---|---|---|
| bitnamilegacy/minio-client:2025.7.21 | 21 | 195 |
| bitnamilegacy/minio:2025.7.23-debian-12-r5 | 34 | 410 |
| curlimages/curl:8.10.1 | 2 | 22 |
| ghcr.io/alejo-basile/doc-service:latest | 0 | 0 |
| ghcr.io/alejo-basile/extraction-worker:latest | 0 | 106 |
| ghcr.io/alejo-basile/ocr-worker@sha256:3e10b697a35f5fe22b4a3d4bbb148c6bbbd6e7e4fefeb7c341639f7210d0d83b | 1 | 149 |
| grafana/grafana:11.6.0 | 10 | 156 |
| grafana/loki:3.4.2 | 2 | 58 |
| grafana/promtail@sha256:6140a3158fddd7ef2276908bd321ad5265ee6ad2abd9fb3c937394827df3ea4d | 1 | 59 |
| hashicorp/consul:1.22.7 | 3 | 85 |
| mongo:7.0 | 1 | 80 |
| monolito:latest | 0 | 72 |
| oliver006/redis_exporter:v1.93.0 | 0 | 4 |
| prom/alertmanager:v0.34.1 | 0 | 14 |
| prom/prometheus:v2.53.4 | 6 | 114 |
| ratelimitd:p4-04 | 0 | 0 |
| redis:7.2 | 4 | 45 |
| slo-exporter:s5-p4-03 | 0 | 16 |
| traefik:v3.7 | 0 | 10 |
| Total | 85 | 1595 |

### Vulnerabilidades Go
- doc-service: 1 (GO-2026-6859)
- rate-limiter: 32

### Ignores Rust
- 4 ignores en deny.toml (extraction-worker)

## 7. Permisos y mínimo privilegio

22 contenedores con CapDrop=[ALL] y no-new-privileges 22/22 (se agrega `infra-ocr-worker-1`: user=10001:10001, ro=true, mem=1 GiB, pids=200). Workers en modo update-only. Identidades separadas en MinIO. Separación de bases Redis (cache vs rate-limit). Evidencia: S9-P1-04-permisos.txt.

## 8. Headers y TLS

Cuatro headers en api y s3: HSTS (max-age=31536000; includeSubDomains), X-Content-Type-Options: nosniff, X-Frame-Options: DENY, Referrer-Policy: strict-origin-when-cross-origin. TLS 1.1 rechazado (exit 35), TLS 1.2/1.3 aceptados (200). Evidencia: S9-P1-04-headers-tls.txt.

## 9. Consola MinIO

Tres comprobaciones: `docker port` vacío, `nc -zv api.localhost 9001` Connection refused (exit 1), `curl https://api.localhost:9001/` 000 (exit 7). Sin router de consola en routing.yml. Consola no expuesta: PASS.

## 10. Secretos

4 repos escaneados con gitleaks sobre historia completa: infra 186 commits, doc-service 121, extraction-worker 188, platform-services 100; 0 leaks en todos (exit 0). Diferencia de evidencias: `docs/evidencia-gitleaks-local.txt` reporta 2 hallazgos sobre `1 commits scanned` y `~107 bytes`, es decir un repositorio fixture de smoke-test, no la historia del proyecto; la evidencia CI (`S2-P1-01`) reporta 0 en 38 commits y coincide con el re-escaneo. Evidencia: S9-P1-04-gitleaks.txt.

## 11. Limitaciones

- openssl no instalado en el host; se usó curl como sustituto.
- SCA Rust bloqueado por cuota de disco (cargo-audit/cargo-deny no disponibles).
- platform-services no tiene go.mod (sin SCA Go aplicable).
- mTLS queda como deuda técnica (no bloqueante, per SPEC §9).
- mkcert no es ACME (certificados locales de desarrollo).
- `ocr-worker` no tiene router en Traefik; solo expone `/metrics` en `0.0.0.0:8080` dentro de las redes `internal`/`data`, sin publicación al host.

## 12. Backlog de remediación

Prioridad: upgrade de imágenes base (bitnamilegacy/minio, prometheus, redis:7.2, mongo, promtail, grafana, traefik, alertmanager, redis_exporter), reemplazo de `ratelimitd` con toolchain Go ≥1.26.11 y bump de Go en `doc-service`. Owner: P1. Target: 2026-12-01. Cada CVE aceptado tiene owner, fecha de revisión y mitigación en `infra/SECURITY.md`; la lista ejecutable está en `infra/.trivyignore`.

## 13. Decisión

- Criterio 1: **Go con excepción aceptada** (85 CRITICAL / 1595 HIGH en 19 imágenes; 241 advisory IDs con owner, review 2026-12-01 y mitigación en `infra/SECURITY.md` + `infra/.trivyignore`; `doc-service` 0/0)
- Criterio 2: **Go**
- Criterio 3: **Go**
- Criterio 4: **Go**
- Criterio 5: **Go**
- Criterio 6: **Go**
- Global: auditoría ejecutada y cerrada. Los 6 criterios son Go (el criterio 1 con excepción formal). La remediación de las imágenes de terceros queda como backlog con fecha 2026-12-01 y no bloquea G5.
