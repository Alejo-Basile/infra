# Política de Seguridad

## Reporte de vulnerabilidades

Este repositorio es público y contiene configuración de infraestructura. Si encuentras una vulnerabilidad o un secreto expuesto:

1. **No** abras una issue pública.
2. Usa la pestaña **Security → Report a vulnerability** (GitHub Private Vulnerability Reporting), o contacta directamente al maintainer: `@Alejo-Basile`.
3. Incluye: archivo/commit afectado, tipo de exposición y pasos para reproducir.

## Reglas permanentes

- Ningún secreto real entra al repo: solo `.env.example` con valores ficticios (SPEC §9).
- Si un secreto llega a un commit: revocar inmediatamente, purgar historial y rotar credenciales.
- Las imágenes base usan pin por digest y los contenedores propios corren como usuario no-root.

## Auditoría de seguridad S9-X-04 (2026-11-17, cerrada 2026-11-18)

- Scope: 4 repos (infra, doc-service, extraction-worker, platform-services). Reabierta 2026-11-18 para incorporar `ocr-worker` (crate `extraction-worker/crates/ocr-worker`) al inventario escaneado y formalizar la política de excepciones.
- Tools: Trivy, gitleaks, govulncheck v1.9.0, docker inspect, curl; openssl and cargo-audit/cargo-deny unavailable (limitations).

| Criterio | Veredicto | Evidencia |
|---|---|---|
| 1. 0 CVE críticos/altos | Go con excepción aceptada (85 CRITICAL / 1595 HIGH en 19 imágenes; 241 advisory IDs aceptados; 0 en `doc-service`) | infra/docs/evidencias/S9/S9-P1-04-trivy.txt, infra/.trivyignore |
| 2. 0 secretos | Go | infra/docs/evidencias/S9/S9-P1-04-gitleaks.txt |
| 3. Headers | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 4. TLS | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 5. Consola MinIO | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 6. Permisos | Go | infra/docs/evidencias/S9/S9-P1-04-permisos.txt |

### Excepciones aceptadas

- RUSTSEC-2026-0258, RUSTSEC-2025-0012, RUSTSEC-2024-0384, RUSTSEC-2026-0192 (owner P1, review 2026-12-31), mitigation from deny.toml.
- Container CVEs: 241 unique advisory IDs accepted as exception, owner P1, review 2026-12-01, mitigation = non-root 10001:10001, read-only rootfs, CapDrop=ALL, no-new-privileges, internal network only, plus the image-upgrade backlog. Full per-ID list in `infra/.trivyignore`; the per-image aggregate table follows below. `doc-service` is clean (0/0); every other image carries base-image CVEs from its upstream distro or vendored binaries, not from project code. Fixable CVEs are NOT silently suppressed: remediation is tracked as an image-upgrade backlog with target date 2026-12-01 (minio, minio-client, grafana, loki, promtail, consul, mongo, monolito, prometheus, redis:7.2, traefik, alertmanager, redis_exporter, curl, slo-exporter, and the Debian base of extraction-worker/ocr-worker).

### Tabla de excepciones por imagen

| Imagen | CRITICAL | HIGH | Estado |
|---|---|---|---|
| `bitnamilegacy/minio-client:2025.7.21` | 21 | 195 | Excepción aceptada |
| `bitnamilegacy/minio:2025.7.23-debian-12-r5` | 34 | 410 | Excepción aceptada |
| `curlimages/curl:8.10.1` | 2 | 22 | Excepción aceptada |
| `ghcr.io/alejo-basile/doc-service:latest` | 0 | 0 | Limpio |
| `ghcr.io/alejo-basile/extraction-worker:latest` | 0 | 106 | Excepción aceptada |
| `ghcr.io/alejo-basile/ocr-worker@sha256:3e10b697a35f5fe22b4a3d4bbb148c6bbbd6e7e4fefeb7c341639f7210d0d83b` | 1 | 149 | Excepción aceptada |
| `grafana/grafana:11.6.0` | 10 | 156 | Excepción aceptada |
| `grafana/loki:3.4.2` | 2 | 58 | Excepción aceptada |
| `grafana/promtail@sha256:6140a3158fddd7ef2276908bd321ad5265ee6ad2abd9fb3c937394827df3ea4d` | 1 | 59 | Excepción aceptada |
| `hashicorp/consul:1.22.7` | 3 | 85 | Excepción aceptada |
| `mongo:7.0` | 1 | 80 | Excepción aceptada |
| `monolito:latest` | 0 | 72 | Excepción aceptada |
| `oliver006/redis_exporter:v1.93.0` | 0 | 4 | Excepción aceptada |
| `prom/alertmanager:v0.34.1` | 0 | 14 | Excepción aceptada |
| `prom/prometheus:v2.53.4` | 6 | 114 | Excepción aceptada |
| `ratelimitd:p4-04` | 0 | 0 | Limpio |
| `redis:7.2` | 4 | 45 | Excepción aceptada |
| `slo-exporter:s5-p4-03` | 0 | 16 | Excepción aceptada |
| `traefik:v3.7` | 0 | 10 | Excepción aceptada |

### Deuda consciente

- mTLS interno (SPEC §9) not resolved; local TLS is mkcert, not ACME.
- platform-services has no Go module for govulncheck.
- cargo SCA not executed (disk quota on /tmp).

### Backlog de remediación

Prioritized image upgrades (minio, prometheus, redis:7.2, mongo, promtail/grafana, extraction-worker base, monolito base, traefik, alertmanager, rate-limiter base, redis_exporter) and Go toolchain bump to >=1.26.11 for doc-service and rate-limiter; owner P1, target 2026-12-01.
