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

## Auditoría de seguridad S9-X-04 (2026-11-17)

- Scope: 4 repos (infra, doc-service, extraction-worker, platform-services).
- Tools: Trivy, gitleaks, govulncheck v1.9.0, docker inspect, curl; openssl and cargo-audit/cargo-deny unavailable (limitations).

| Criterio | Veredicto | Evidencia |
|---|---|---|
| 1. 0 CVE críticos/altos | No-Go (46 CRITICAL / 942 HIGH) | infra/docs/evidencias/S9/S9-P1-04-trivy.txt |
| 2. 0 secretos | Go | infra/docs/evidencias/S9/S9-P1-04-gitleaks.txt |
| 3. Headers | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 4. TLS | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 5. Consola MinIO | Go | infra/docs/evidencias/S9/S9-P1-04-headers-tls.txt |
| 6. Permisos | Go | infra/docs/evidencias/S9/S9-P1-04-permisos.txt |

### Excepciones aceptadas

- RUSTSEC-2026-0258, RUSTSEC-2025-0012, RUSTSEC-2024-0384, RUSTSEC-2026-0192 (owner P1, review 2026-12-31), mitigation from deny.toml.
- NO exception accepted for container CVEs: 46 CRITICAL / 942 HIGH remain open and block G5.

### Deuda consciente

- mTLS interno (SPEC §9) not resolved; local TLS is mkcert, not ACME.
- platform-services has no Go module for govulncheck.
- cargo SCA not executed (disk quota on /tmp).

### Backlog de remediación

Prioritized image upgrades (minio, prometheus, redis:7.2, mongo, promtail/grafana, extraction-worker base, monolito base, traefik, alertmanager, rate-limiter base, redis_exporter) and Go toolchain bump to >=1.26.11 for doc-service and rate-limiter; owner P1, target 2026-12-01.
