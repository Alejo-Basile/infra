#!/usr/bin/env bash
# Deploy reproducible del doc-service desde GHCR (S3-P1-01).
# Uso: ./scripts/deploy-doc-service.sh <tag>
set -euo pipefail

TAG="${1:?uso: deploy-doc-service.sh <tag>}"
INFRA_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$INFRA_ROOT"

COMPOSE=(docker compose -f compose/docker-compose.yml --env-file .env --profile full)
export DOC_SERVICE_TAG="$TAG"

echo "== pull doc-service:$TAG =="
"${COMPOSE[@]}" pull doc-service

echo "== up -d --no-build doc-service =="
"${COMPOSE[@]}" up -d --no-build doc-service

CID="$("${COMPOSE[@]}" ps -q doc-service)"
if [ -z "$CID" ]; then
  echo "FAIL: doc-service no quedo creado"
  exit 1
fi

echo "== esperando healthy =="
for _ in $(seq 1 30); do
  [ "$(docker inspect -f '{{.State.Health.Status}}' "$CID")" = "healthy" ] && break
  sleep 2
done

STATUS="$(docker inspect -f '{{.State.Health.Status}}' "$CID")"
if [ "$STATUS" != "healthy" ]; then
  echo "FAIL: contenedor $STATUS"
  docker logs --tail 40 "$CID" || true
  exit 1
fi

echo "== smoke E2E por Traefik =="
CODE="$(curl -sk -o /dev/null -w '%{http_code}' https://api.localhost:8543/healthz)"
if [ "$CODE" != "200" ]; then
  echo "FAIL: /healthz -> $CODE"
  exit 1
fi

echo "OK: doc-service $TAG healthy, /healthz 200"
echo -n "digest: "
docker inspect -f '{{range .RepoDigests}}{{println .}}{{end}}' "$CID" | head -1
