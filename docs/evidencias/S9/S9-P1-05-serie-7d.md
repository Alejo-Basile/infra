# S9-P1-05 — Serie 7 días (tráfico legacy)

## Resultado
Dataset inicial 2026-11-17. Business total: 2. Technical total: 3.

## Definición operativa
Business routes (cuentan para condición): POST /pdf/process, GET /registros, GET /registros/hash/{hash}, GET /registros/{id}, PUT /registros/{id}, DELETE /registros/{id}.
Technical routes (reportadas aparte): GET /health, /health/ready, /docs, /redoc, /openapi.json.

## Condición de apagado
0 peticiones de negocio durante 7 días consecutivos UTC completos. Un solo request invalida la racha; un día incompleto reinicia la racha.

## Estado actual
0 días consecutivos completos con 0 negocio. Último request de negocio (StartUTC): 2026-11-17T19:39:56.541150326Z (2 requests business en el corte).

## G5-PREP vs G5-APAGADO
G5-PREP (04/12) puede habilitar canary; no certifica apagado. G5-APAGADO solo al completar 7 días.