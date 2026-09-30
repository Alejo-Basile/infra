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
