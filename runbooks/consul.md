# Runbook: Consul (configuración distribuida, S11)

Alertas que enlazan acá (`runbook_url` en `compose/prometheus/alert.rules.yml`):
`ConsulServerDown`, `ConsulNoLeader`, `ConfigKVStale`, `ConfigKVRejected`.

Aviso honesto: no todas esas alertas significan "Consul cayó". `ConfigKVStale` y
`ConfigKVRejected` pueden dispararse por un valor inválido en caliente o por un
servicio sin caché; en esos casos Consul puede estar sano. `ConsulServerDown` y
`ConsulNoLeader` sí apuntan al plano de control: revisá primero esos.

Todos los comandos asumen que estás en la raíz del repo `infra`:

```bash
cd infra
C="docker compose -f compose/docker-compose.yml --env-file .env"
```

Sin `--env-file .env`, Compose no ve `CONSUL_IMAGE_TAG`, `CONSUL_HTTP_ADDR`, etc.

## Topología desplegada (verificada S11)

| Elemento | Valor |
| --- | --- |
| Server | `consul` (single-node, `bootstrap_expect=1`) |
| Agent | `consul-agent` (cliente, registro de servicios) |
| KV sync | `consul-kv-sync` (one-shot, perfil `discovery`) |
| TLS | HTTPS 8501, `verify_server_hostname`, CA en `consul_ca_cert` |
| Gossip | cifrado (`consul_gossip_key.txt`) |
| ACL | `default deny`; token por servicio |
| Puertos | 8501 HTTPS, 8300, 8301 tcp+udp, 8302, 8600 |

Limitación conocida: single-node, sin HA real, sin mTLS entre agentes/server,
sin autoscaling real (diferidos, ver §10).

## 1. Arranque / parada

```bash
$C --profile discovery up -d consul consul-agent consul-kv-sync
$C --profile discovery ps
```

Orden: server → agent → kv-sync → apps. Verificar líder:

```bash
$C exec -T consul consul members
$C exec -T consul consul operator raft list-peers
```

Esperado: un peer, `Leader: true`. Parada:

```bash
$C --profile discovery stop consul consul-agent consul-kv-sync
```

Fallo: si `consul members` no responde en 30 s, revisar `docker logs infra-consul-1`.

## 2. Líder y quórum

Single-node: el server es líder único, `bootstrap_expect=1`. No hay quórum a
recuperar. Si el líder no se elige en 30 s: revisar logs, verificar que el
volumen `consul-data` no esté corrupto; recrear solo el contenedor (no el
volumen) y reintentar. HA diferido (§10).

## 3. Bootstrap ACL

```bash
bash scripts/consul-bootstrap-acl.sh
```

Idempotente: si el token responde, no re-bootstrapea. Imprime prefijo de 8
caracteres del token. Verificación: `consul acl token read -self` con el token
de operador. Fallo: si re-bootstrapea, los tokens viejos quedan inválidos;
restaurar desde snapshot.

## 4. Rotación de tokens

1. Generar nuevo token: `consul acl token create -policy-name=...`.
2. Actualizar Docker secret correspondiente en `infra/secrets/`.
3. Reiniciar el servicio afectado.
4. Revocar el anterior: `consul acl token delete`.
5. Verificar lectura cruzada → 403.

Fallo: si un servicio queda con token viejo, reiniciar con el nuevo secret.

## 5. Pérdida de gossip key

Síntomas: agentes no se unen, `consul members` vacío. Recuperación:

```bash
consul keygen   # nuevo
# actualizar infra/secrets/consul_gossip_key.txt en server y agent
$C --profile discovery restart consul consul-agent
$C exec -T consul consul keyring -list
```

Esperado: `encryption: enabled`. Fallo: si la key no coincide entre server y
agent, el agent no entra al cluster.

## 6. Pérdida de quórum

No aplica en single-node. Referencia al retiro completo (§10) y a la HA
diferida (§10 del plan). Nunca borrar volúmenes.

## 7. Snapshot / restore

Contrato: `infra/scripts/consul-snapshot.sh save → inspect → restore --yes`.

```bash
CONSUL_HTTP_ADDR=https://consul:8501 bash infra/scripts/consul-snapshot.sh save --out /tmp/snap
bash infra/scripts/consul-snapshot.sh inspect /tmp/snap
bash infra/scripts/consul-snapshot.sh restore --yes /tmp/snap   # requiere --yes
```

Sin `--yes`, exit 2. Seguridad: el script rehúsa restore cuando el host
resuelto es `consul` (volumen real) salvo `--force-real-target`. Ensayar SIEMPRE
en volumen desechable `consul-snapshot-test`, nunca en `consul-data`. Ver
evidencia `S11-P1-C26-snapshot.txt`.

Fallo: si restore falla a mitad, el cluster queda inconsistente; restaurar
desde snapshot previo verificado.

## 8. Tabla de claves que exigen reinicio

| Clave | Modo | Nota |
| --- | --- | --- |
| `config/extraction-worker/min_idle_ms` | restart | No se recomputa cuando `job_timeout_seconds` cambia en caliente |
| reducción de `bulkhead_max_concurrency` | restart (nunca a la fuerza) | |
| `OCR_*`, `REDIS_OCR_*` | restart (cuando aterrice) | bloque OCR |

El resto de claves son hot / hot-aumento / hot-jobs-nuevos.

## 9. Degradación

- Consul caído al arrancar con caché: el servicio usa último valor válido.
- Consul caído al arrancar sin caché: aplica defaults.
- Valor inválido en caliente: rechazado, se mantiene el anterior (`ConfigKVRejected`).
- Reconexión con backoff; verificar `config_kv_stale` y defaults.

Evidencia: `infra/docs/evidencias/S11/S11-P1-C23-degradacion.txt`.

## 10. Retiro completo

1. `docker compose --profile discovery stop consul consul-agent consul-kv-sync`.
2. Quitar bloques del compose y archivos nuevos (§5.2 del plan).
3. Revertir modificaciones (§5.3 del plan).
4. `docker compose --profile full up -d` + smoke por Traefik.
5. Nunca borrar volúmenes de mongo, redis-*, minio ni prometheus.

## Estado del ensayo

Snapshot/restore ensayado en volumen desechable; ver `S11-P1-C26-snapshot.txt`.
Trivy y gitleaks archivados en `S11-P1-C26-trivy.txt` y `S11-P1-C26-gitleaks.txt`.
EOF
echo done