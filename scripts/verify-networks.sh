#!/usr/bin/env bash
# Verificacion de la topologia de redes — S0-P1-05 (DoD)
# 1. internal/data son redes SIN salida a internet
# 2. prueba de conectividad negativa desde un contenedor de datos
set -u

fail=0
COMPOSE="docker compose -f compose/docker-compose.yml --profile core"

echo "== 1. Inspeccion de redes =="
for net in infra_internal infra_data; do
  internal=$(docker network inspect "$net" --format '{{.Internal}}' 2>/dev/null || echo "NO-EXISTE")
  if [ "$internal" = "true" ]; then
    echo "  [OK] $net es interna (internal: true)"
  elif [ "$internal" = "NO-EXISTE" ] && [ "$net" = "infra_internal" ]; then
    echo "  [SKIP] $net no existe todavia (se crea con el perfil full; en core no se usa)"
  else
    echo "  [FALTA] $net internal=$internal (debe ser true y existir; levanta el perfil core antes)"
    fail=$((fail+1))
  fi
done

echo "== 2. Conectividad negativa (un contenedor de datos NO debe salir) =="
if docker ps --format '{{.Names}}' | grep -q 'redis-streams'; then
  if $COMPOSE exec -T redis-streams sh -c 'wget -q -T 3 -O- http://8.8.8.8 >/dev/null 2>&1' 2>/dev/null; then
    echo "  [FALLO] redis-streams SI tiene salida a internet"
    fail=$((fail+1))
  else
    echo "  [OK] redis-streams NO tiene ruta a internet"
  fi
else
  echo "  [SKIP] redis-streams no esta corriendo (levanta: $COMPOSE up -d)"
fi

echo
[ "$fail" -eq 0 ] && echo "Topologia OK." || { echo "Hay $fail fallo(s)."; exit 1; }
