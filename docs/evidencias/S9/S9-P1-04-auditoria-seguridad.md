# S9-X-04 — Auditoría de seguridad final

Fecha: 2026-11-17

## 1. Resumen ejecutivo

Se ejecutó la auditoría de seguridad final sobre los 4 repositorios del proyecto (infra, doc-service, extraction-worker, platform-services), cubriendo imágenes de contenedor, secretos, SCA Go/Rust, permisos y mínimo privilegio, headers y TLS, consola MinIO y SCA de dependencias. Resultado global: la auditoría se ejecutó completa; el criterio 1 (imágenes base) es No-Go (46 CRITICAL / 942 HIGH sin excepción aceptada). Los criterios 2 a 6 son Go. El gate G5 queda bloqueado únicamente por el criterio 1.

## 2. Alcance

| Repositorio | Qué se verificó |
|---|---|
| infra | Imágenes Docker (trivy), secretos (gitleaks), permisos de contenedores, headers/TLS, consola MinIO, SCA |
| doc-service | Imágenes Docker (trivy), secretos (gitleaks), govulncheck |
| extraction-worker | Imágenes Docker (trivy), secretos (gitleaks), SCA Rust (cargo-audit/cargo-deny, bloqueado por cuota de disco) |
| platform-services | Secretos (gitleaks); sin go.mod (sin SCA Go aplicable) |

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

### 5.1 Criterio 1 — Imágenes base (No-Go)
46 CRITICAL / 942 HIGH. Evidencia: S9-P1-04-trivy.txt.

### 5.2 Criterio 2 — Secretos (Go)
0 leaks en 4 repos. Evidencia: S9-P1-04-gitleaks.txt.

### 5.3 Criterio 3 — Headers (Go)
4 headers observados en api y s3 (HSTS, X-Content-Type-Options, X-Frame-Options, Referrer-Policy). Evidencia: S9-P1-04-headers-tls.txt.

### 5.4 Criterio 4 — TLS (Go)
TLS 1.1 rechazado (exit 35), TLS 1.2/1.3 aceptados (200). Evidencia: S9-P1-04-headers-tls.txt.

### 5.5 Criterio 5 — Consola MinIO (Go)
No expuesta (puerto vacío, nc refused, curl 000, sin router). Evidencia: S9-P1-04-headers-tls.txt.

### 5.6 Criterio 6 — Permisos y mínimo privilegio (Go)
21/21 CapDrop=[ALL], non-root, worker update-only, identidades MinIO, separación Redis. Evidencia: S9-P1-04-permisos.txt.

## 6. Hallazgos

### CVE por imagen (container)

| Imagen | CRITICAL | HIGH |
|---|---|---|
| bitnamilegacy/minio:2025.7.23-debian-12-r5 | 34 | 410 |
| ghcr.io/alejo-basile/doc-service:latest | 0 | 0 |
| ghcr.io/alejo-basile/extraction-worker:s5p1-closure | 0 | 107 |
| grafana/grafana:12.4.14 | 0 | 4 |
| grafana/promtail | 1 | 59 |
| loki:3.6.20-healthcheck | 0 | 0 |
| mongo:7.0 | 1 | 80 |
| monolito:latest | 0 | 72 |
| oliver006/redis_exporter | 0 | 4 |
| prom/alertmanager | 0 | 14 |
| prom/prometheus:v2.53.4 | 6 | 114 |
| ratelimitd:p4-04 | 0 | 23 |
| redis:7.2 | 4 | 45 |
| redis:7.2-alpine3.22 | 0 | 0 |
| traefik:v3.7 | 0 | 10 |
| Total | 46 | 942 |

### Vulnerabilidades Go
- doc-service: 1 (GO-2026-6859)
- rate-limiter: 32

### Ignores Rust
- 4 ignores en deny.toml (extraction-worker)

## 7. Permisos y mínimo privilegio

21 contenedores con CapDrop=[ALL] y no-new-privileges 21/21. Workers en modo update-only. Identidades separadas en MinIO. Separación de bases Redis (cache vs rate-limit). Evidencia: S9-P1-04-permisos.txt.

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

## 12. Backlog de remediación

Prioridad: upgrade de imágenes base (bitnamilegacy/minio, prometheus, redis, mongo, promtail) y bump de toolchain Go. Owner: P1. Target: 2026-12-01.

## 13. Decisión

- Criterio 1: **No-Go** (46 CRITICAL / 942 HIGH, sin excepción aceptada)
- Criterio 2: **Go**
- Criterio 3: **Go**
- Criterio 4: **Go**
- Criterio 5: **Go**
- Criterio 6: **Go**
- Global: auditoría ejecutada; G5 bloqueado únicamente por el criterio 1 (imágenes base).
