#!/bin/bash
# Prueba integrada aislada para S4-P1-03: QueueNotAdvancing y DLQNotEmpty
# Verifica que las alertas pasan a 'firing' cuando se provocan artificialmente

set -euo pipefail

# Rutas relativas al propio script: funciona desde cualquier directorio.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMPOSE_FILE="$REPO_ROOT/compose/docker-compose.test-alerts.yml"
PROJECT_NAME="s4p103-test"
PROMETHEUS_URL="http://prometheus-test:9090"

# Credencial efimera del stack aislado: se genera en cada ejecucion y nunca
# se versiona. El compose la inyecta via REDIS_TEST_PASSWORD (fail-fast si falta).
export REDIS_TEST_PASSWORD="$(openssl rand -hex 16)"

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

# 2. Agregar mensaje al stream principal y esperar 5 min para QueueNotAdvancing
echo ""
echo ">>> Test 1: QueueNotAdvancing - Agregando mensaje al stream principal..."
redis_cli XADD stream:s4p103-test '*' payload '{"document_id":"test-queue"}'

echo ">>> Esperando 5 minutos para que changes()[5m] evalúe profundidad constante..."
sleep 300

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

# 3. Agregar mensaje a DLQ para DLQNotEmpty
echo ""
echo ">>> Test 2: DLQNotEmpty - Agregando mensaje a DLQ..."
redis_cli XADD stream:s4p103-test-dlq '*' payload '{"document_id":"test-dlq"}'

echo ">>> Esperando 10 segundos para que Prometheus scrapee y evalúe la regla..."
sleep 10

# Verificar alerta DLQNotEmpty
echo ">>> Verificando alerta DLQNotEmpty en Prometheus..."
ALERTS=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty") | .state')
if echo "$ALERTS" | grep -q "firing"; then
    echo "✓ DLQNotEmpty: FIRING"
else
    echo "✗ DLQNotEmpty: NO FIRING (estado: $ALERTS)"
    docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty")'
fi

# 4. Limpiar mensajes de prueba
echo ""
echo ">>> Limpiando mensajes de prueba..."
redis_cli XDEL stream:s4p103-test 0
redis_cli XDEL stream:s4p103-test-dlq 0

# Verificar que las alertas se resuelven
sleep 10
echo ">>> Verificando resolución de alertas..."
QUEUE_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="QueueNotAdvancing") | .state // "inactive"')
DLQ_STATE=$(docker run --rm --network s4p103_test_internal curlimages/curl:8.7.1 curl -s "$PROMETHEUS_URL/api/v1/alerts" | jq -r '.data.alerts[] | select(.labels.alertname=="DLQNotEmpty") | .state // "inactive"')

echo "QueueNotAdvancing state: $QUEUE_STATE"
echo "DLQNotEmpty state: $DLQ_STATE"

# 5. Detener stack aislado
echo ""
echo ">>> Deteniendo stack aislado..."
docker compose -f "$COMPOSE_FILE" -p "$PROJECT_NAME" down -v

echo ""
echo "=== Prueba integrada completada ==="