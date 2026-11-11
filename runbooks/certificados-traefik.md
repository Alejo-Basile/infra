# Runbook: certificados TLS y ACME de Traefik

Aplica a `AcmeCertificateExpiring` (menos de 14 días). No borres ni reemplaces el almacenamiento ACME durante el diagnóstico.

## Diagnóstico

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml logs --since 1h traefik | grep -iE 'acme|certificate|challenge|renew'
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml exec -T traefik traefik healthcheck
```

Confirma hostname y resolver ACME, DNS/alcance del challenge, permisos y espacio del almacenamiento configurado. Comprueba que el router sirve el certificado vigente desde un cliente autorizado; no publiques el contenido de `acme.json`.

## Recuperación

Corrige primero DNS, challenge o configuración del resolver. Espera la renovación automática y vuelve a comprobar la fecha de expiración servida. Si la renovación falla, escala al responsable de dominio/ACME; evita solicitudes repetidas que puedan activar límites del proveedor.

## Cierre

Registra hostname no sensible, causa, renovación observada y expiración nueva. Nunca archives claves privadas ni el archivo ACME.
