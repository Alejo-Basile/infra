#!/bin/bash
# Prueba integrada aislada de alertas Redis Streams y recepción en Alertmanager.

set -euo pipefail

# Rutas relativas al propio script: funciona desde cualquier directorio.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.test-alerts.yml"
PROJECT_NAME="s4p103-test"
PROMETHEUS_URL="http://prometheus-test:9090"
ALERTMANAGER_URL="http://alertmanager-test:9093"

# Credencial efimera del stack aislado: se genera en cada ejecucion y nunca
# se versiona. El compose la inyecta via REDIS_TEST_PASSWORD (fail-fast si falta).
export REDIS_TEST_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_hex(16))')"

# redis-cli sin password en argv: REDISCLI_AUTH viaja como env al contenedor.
redis_cli() {
    docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" exec -T \
        -e REDISCLI_AUTH="$REDIS_TEST_PASSWORD" redis-test redis-cli "$@"
}

echo "=== S4-P1-03 Prueba Integrada Isolada ==="
echo "Fecha: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo "Directorio: $(pwd)"
echo ""

# 1. Levantar stack aislado
echo ">>> Levantando stack aislado..."
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" up -d --build

# Esperar a que los servicios estén healthy
echo ">>> Esperando a que Redis y exporter estén listos..."
sleep 5

# Verificar redis-exporter (usar curl desde contenedor externo)
# El exporter está up si responde con métricas (redis_up 1), aunque los streams aún no existan
for i in {1..30}; do
    if docker run --rm --network s4p103_test_data curlimages/curl:8.7.1 curl -s http://redis-exporter-test:9121/metrics 2>/dev/null | grep -q "redis_up 1"; then
        echo "✓ redis-exporter respondiendo (redis_up=1)"
        break
    fi
    sleep 1
    if [ $i -eq 30 ]; then
        echo "✗ Timeout esperando redis-exporter"
        exit 1
    fi
done

# 1b. Family fixture drives the thresholds through the same Prometheus ->
# Alertmanager path without inducing live infrastructure failures.
FAMILY_ALERTS=(QueueDepthHigh PELBacklog ExtractionErrors SentinelFailoverObserved RedisPersistenceOrReplicaIssue HighErrorRate TraefikRateLimited AcmeCertificateExpiring MinioDiskHigh DocsStuck DocServiceNotReady)
echo ">>> Verificando las 10 familias sintéticas en Prometheus y Alertmanager..."
sleep 20
for alert in "${FAMILY_ALERTS[@]}"; do
    PROM_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -fsS "$PROMETHEUS_URL/api/v1/alerts" | jq -r --arg name "$alert" '[.data.alerts[] | select(.labels.alertname==$name) | .state] | first // empty')
    if [ "$PROM_STATE" != "firing" ]; then
        echo "✗ $alert: NO FIRING (estado: ${PROM_STATE:-ausente})"
        exit 1
    fi
    AM_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -fsS "$ALERTMANAGER_URL/api/v2/alerts" | jq -r --arg name "$alert" '[.[] | select(.labels.alertname==$name) | .status.state] | first // empty')
    if [ "$AM_STATE" != "active" ]; then
        echo "✗ $alert: Alertmanager no la recibió (estado: ${AM_STATE:-ausente})"
        exit 1
    fi
    echo "✓ $alert: FIRING; Alertmanager active"
done

# 2. Agregar mensaje al stream principal y esperar 5 min para QueueNotAdvancing
echo ""
echo ">>> Test 1: QueueNotAdvancing - Agregando mensaje al stream principal..."
redis_cli DEL stream:s4p103-test stream:s4p103-test-dlq >/dev/null
QUEUE_ID=$(redis_cli XADD stream:s4p103-test '*' payload '{"document_id":"test-queue"}' | tr -d '\r')

echo ">>> Esperando 5 minutos de ventana más un ciclo de evaluación de 30s..."
sleep 330

# Verify stream length is constant
echo ">>> Verificando que la profundidad del stream se mantiene constante..."
for i in {1..5}; do
    LEN=$(redis_cli XLEN stream:s4p103-test 2>/dev/null | tr -d '\r')
    echo "    XLEN stream:s4p103-test = $LEN (iteración $i)"
    sleep 1
done

# Verificar alerta QueueNotAdvancing
echo ">>> Verificando alerta QueueNotAdvancing en Prometheus..."
ALERTS=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="QueueNotAdvancing") | .state')
if echo "$ALERTS" | grep -q "firing"; then
    echo "✓ QueueNotAdvancing: FIRING"
else
    echo "✗ QueueNotAdvancing: NO FIRING (estado: $ALERTS)"
    docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq '.data.alerts[] | select(.labels.alertname=="QueueNotAdvancing")'
fi
echo ">>> Confirmando recepción en Alertmanager..."
AM_ALERTS=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -fsS "$ALERTMANAGER_URL/api/v2/alerts")
if echo "$AM_ALERTS" | jq -e '.[] | select(.labels.alertname=="QueueNotAdvancing")' >/dev/null; then
    echo "✓ Alertmanager recibió QueueNotAdvancing"
else
    echo "✗ Alertmanager aún no recibió QueueNotAdvancing"
    exit 1
fi

# 3. Agregar mensaje a DLQ para DLQNotEmpty
echo ""
echo ">>> Test 2: DLQNotEmpty - Agregando mensaje a DLQ..."
DLQ_ID=$(redis_cli XADD stream:s4p103-test-dlq '*' payload '{"document_id":"test-dlq"}' | tr -d '\r')

echo ">>> Esperando un ciclo completo de evaluación y recepción de Alertmanager..."
sleep 45

# Verificar alerta DLQNotEmpty
echo ">>> Verificando alerta DLQNotEmpty en Prometheus..."
ALERTS=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty") | .state')
if echo "$ALERTS" | grep -q "firing"; then
    echo "✓ DLQNotEmpty: FIRING"
else
    echo "✗ DLQNotEmpty: NO FIRING (estado: $ALERTS)"
    docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty")'
fi
echo ">>> Confirmando recepción DLQ en Alertmanager..."
AM_ALERTS=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -fsS "$ALERTMANAGER_URL/api/v2/alerts")
if echo "$AM_ALERTS" | jq -e '.[] | select(.labels.alertname=="DLQNotEmpty")' >/dev/null; then
    echo "✓ Alertmanager recibió DLQNotEmpty"
else
    echo "✗ Alertmanager aún no recibió DLQNotEmpty"
    exit 1
fi

# 4. Limpiar mensajes de prueba
echo ""
echo ">>> Limpiando mensajes de prueba..."
redis_cli XDEL stream:s4p103-test "$QUEUE_ID"
redis_cli XDEL stream:s4p103-test-dlq "$DLQ_ID"

# Verificar que las alertas se resuelven
sleep 10
echo ">>> Verificando resolución de alertas..."
QUEUE_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="QueueNotAdvancing") | .state // "inactive"')
DLQ_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty") | .state // "inactive"')

echo "QueueNotAdvancing state: $QUEUE_STATE"
echo "DLQNotEmpty state: $DLQ_STATE"

# 5. Detener (sin borrar volúmenes) el stack aislado
echo ""
echo ">>> Deteniendo stack aislado..."
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" stop

echo ""
echo "=== Prueba integrada completada ==="
