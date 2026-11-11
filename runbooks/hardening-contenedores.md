# Runbook: hardening de contenedores

Este procedimiento comprueba el aislamiento del filesystem, usuario, capacidades, límites y referencias de imagen. Ejecuta primero en staging y conserva solo salidas filtradas: nunca publiques `docker inspect` sin `--format` ni la salida interpolada de `docker compose config`.

## Verificación rápida

```bash
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml config -q
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml config --images
docker compose --env-file infra/.env -f infra/compose/docker-compose.yml ps
docker inspect --format '{{.Name}} user={{.Config.User}} ro={{.HostConfig.ReadonlyRootfs}} caps={{.HostConfig.CapDrop}} sec={{.HostConfig.SecurityOpt}}' <contenedor>
docker port <contenedor>
```

La inspección de runtime debe hacerse contenedor por contenedor y comprobar también `CapAdd`, `Memory`, `NanoCpus` y `PidsLimit` con formatos específicos. `config --images` permite revisar tags/digests sin mostrar variables de entorno. No usar `config` sin `-q` en sesiones donde el entorno contenga credenciales.

## Postura aplicada y excepciones

Los servicios de aplicación y datos se ejecutan con UID numérica no-root y rootfs de solo lectura. Mongo y Redis escriben únicamente en sus volúmenes de datos; MinIO escribe en su volumen `/bitnami/minio/data`. Los init jobs Bitnami ejecutan UID 1001 y `HOME=/tmp`, porque `mc` intentaba escribir `/.mc` con `HOME` implícito; `/tmp` es tmpfs y conserva el rootfs RO.

Redis Streams presentó ficheros AOF root-owned heredados de la ejecución anterior como root. Se corrigió solo el owner de `appendonlydir` en los tres volúmenes a 999:999 (sin borrar/recrear datos), después de lo cual Redis inició como UID 999 y pasó su healthcheck. Verificar propiedad después de migrar volúmenes preexistentes.

Traefik ejecuta UID 65532, conserva rootfs RO y añade `NET_BIND_SERVICE` para bindear 80/443. `group_add` usa `DOCKER_SOCKET_GID` (default 969 observado en este host) para acceso de solo lectura al socket Docker; ajustar el GID por host. Las capabilities SETUID/SETGID/CHOWN/DAC_OVERRIDE se mantienen solo en el ancla de servicios de datos que usan entrypoints oficiales; revisar al cambiar imágenes/entrypoints.

El worker usa `USER 10001:10001`, rootfs RO, tmpfs `/tmp`, y 768 MiB/1.5 CPU/200 PID. Con bulkhead de cuatro, la extrapolación de PDFs medida fue ~436 MiB. La imagen runtime se actualizó a Debian Trixie fijado por digest; CVE-2023-45853 en el Debian Bookworm previo desapareció en scan con Trivy.

Los tags locales `monolito:latest` y `doc-service:local` son excepciones de build; Compose no se verificó construyendo directamente sobre `name@sha256:<image-id>`. IDs observados: monolito `sha256:0439e6a932d8ff40e5401bd574baa7d392f8ba35cd623e4ee34aec1f067442ef`, doc-service local `sha256:a6709491bee5577fe612d8c5237a75aec4b635f569de587602f7187128b09147`. Registrar el nuevo ID después de cada build local.

## Límites de recursos desplegados

| Servicio/grupo | Memoria | CPU | PID |
|---|---:|---:|---:|
| Mongo, MinIO | 1 GiB | 1.0 | 200 |
| Redis Streams y réplicas | 256 MiB | 0.5 | 100 |
| Redis rate-limit | 128 MiB | 0.25 | 100 |
| Sentinel | 128 MiB | 0.25 | 50 |
| Mongo-init | 256 MiB | 0.5 | 100 |
| MinIO init jobs | 128 MiB | 0.25 | 100 |
| Worker | 768 MiB | 1.5 | 200 |
| Doc-service | 512 MiB | 1.0 | 300 |
| Monolito | 512 MiB | 1.0 | 200 |
| Prometheus, Loki, Grafana | 512 MiB | 0.5 | 100 |
| Alertmanager, redis-exporter | 128 MiB | 0.25 | 50 |
| Traefik | 256 MiB | 0.5 | 100 |
| Pumba (perfil chaos) | 64 MiB | 0.1 | 50 |
| Fixture alertas: Redis/exporter | 128 MiB | 0.25 | 100/50 |
| Fixture alertas: nginx | 64 MiB | 0.1 | 25 |
| Fixture alertas: Prometheus/Alertmanager | 512/128 MiB | 0.5/0.25 | 100/50 |

Los límites se calibran con mediciones; el worker necesita preservar capacidad de readiness durante cuatro extracciones simultáneas.

## Digest y escaneo

Para fijar una imagen publicada, resolver y revisar el digest del registro, actualizar el compose a `repositorio@sha256:...` y dejar el tag legible como comentario. Confirmar con `docker compose ... config --images` y desplegar en staging. No tratar tags locales como digest de registro: guardar su image ID y reconstruirlos desde el Dockerfile.

CI de `doc-service`, `extraction-worker` y la imagen derivada de Loki (sonda `/ready`) construye cada imagen y ejecuta Trivy con severidad `CRITICAL` y `exit-code: 1`; no hay `continue-on-error` ni `ignore-unfixed`. Un hallazgo crítico bloquea el pipeline.

Versiones actualizadas y fijadas: Mongo `7.0.45`, Redis `7.2-alpine3.22`, Prometheus `3.16.0`, Loki `3.6.20` (base de `loki:3.6.20-healthcheck`), Grafana `12.4.14`, Pumba `0.11.10`; los digests están en `docker-compose.yml`. Redis conserva la línea 7.2; Prometheus/Loki/Grafana avanzaron versión porque los releases previos no contenían los fixes Trivy requeridos.

Excepciones explícitas del scan: Mongo 7.0.45 sigue incluyendo gosu con `CVE-2025-68121`; no hay release Mongo 7.0 con gosu corregido. El servicio ejecuta como UID 999 y el entrypoint no invoca gosu para cambiar de usuario. El riesgo residual y la razón para no actualizar Mongo 8 con volúmenes 7.0 están en `infra/SECURITY.md`.

MinIO y minio-client Bitnami legacy no publican builds después de agosto de 2025; Docker Hub no tiene `minio/minio`/`minio/mc` y la consulta Quay falló con 502. Los CVE, el riesgo residual y las mitigaciones compensatorias de estas imágenes abandonadas están documentados en `infra/SECURITY.md` y la evidencia. Ningún finding se suprime.

Loki upstream es distroless y no incluye cliente HTTP. La imagen local `loki:3.6.20-healthcheck` añade solo el applet `wget` de BusyBox fijado por digest para consultar `/ready`; su image ID está en la evidencia. Redis-exporter tampoco trae shell, `wget` o `curl`: excepción de healthcheck, con Prometheus monitoreando `up{job="redis-exporter"}` y alerta cuando cae a cero.

## Ajuste de límites

Medir memoria pico y CPU bajo PDFs válidos cercanos al límite, PDFs patológicos y concurrencia máxima. Reducir concurrencia del worker si el pico supera el presupuesto del contenedor; mantener el margen para healthcheck y shutdown. Cambiar `mem_limit`, `cpus` o `pids_limit` de forma acotada y volver a ejecutar carga y readiness antes de promover.

## Reversión

Revertir solo los cambios T5 que provoquen fallo, manteniendo los cambios T1–T4:

1. En `infra/compose/docker-compose.yml`, restaurar la referencia de imagen previa al digest fallido y revertir únicamente `user`, `read_only`/`tmpfs`, `cap_add`/`group_add`, límites o healthcheck que causaron el problema. Para el worker, volver temporalmente a la referencia anterior solo si Debian Trixie rompe compatibilidad; registrar que se reintroduce un CVE ya corregido.
2. En `docker-compose.test-alerts.yml`, revertir solo la opción de usuario/capacidad/rootfs que rompa el fixture. Los overrides build/local se dejan como tags locales y se actualizan con el image ID nuevo.
3. Para gates CI, mantener el job Trivy y corregir la causa; no introducir `continue-on-error`, `ignore-unfixed` ni supresiones para esconder un fallo.
4. Recrear solo los servicios afectados con los overlays/profile que corresponden y validar `ps`, healthchecks, conectividad y persistencia. No borrar ni recrear volúmenes. Los archivos AOF de Streams quedaron con owner 999:999; preservar esa propiedad al revertir para evitar pérdida de acceso a los datos.

Para un digest defectuoso, volver al digest previo registrado, nunca a un tag flotante. Un rollback de código/imagen no revierte los permisos no destructivos ya corregidos en los volúmenes.
