# ADR-0001 — Migrar a microservicios y no a un monolito modular

- **Estado:** Propuesto (a aceptar en la revisión de arquitectura de S0)
- **Fecha:** Semana 0 (S0-P4-03)
- **Owner:** P4
- **Revisada por:** P1, P2, P3
- **Contexto:** `SPEC.md` v2.1 §1–§3 · `pasos-iniciales.md` §5.4 · `S0-P4-01`

## Contexto

El monolito actual es una API FastAPI que, en una sola unidad desplegable, valida el PDF,
extrae el texto, genera el `.txt`, persiste metadatos en MongoDB y orquesta el flujo completo.
El cuello de botella no es el lenguaje: es que **la extracción de PDF (CPU y memoria, con
entradas hostiles) comparte proceso y ciclo de despliegue con la API síncrona** que debe
responder en menos de 500 ms p95.

El equipo es pequeño y junior en sistemas distribuidos. La decisión debe reconocer ese costo:
migrar a microservicios agrega red, consistencia eventual, observabilidad distribuida y
operación. No se elige por moda.

## Opciones consideradas

1. **Monolito modular** — separar internamente API, extracción y persistencia, manteniendo un
   único despliegue.
   - A favor: menor complejidad operativa, transacciones locales, un solo pipeline.
   - En contra: el worker de extracción no escala de forma independiente; un PDF hostil puede
     agotar CPU/RAM del proceso que atiende la API; el límite de concurrencia de extracción
     queda acoplado al de las requests.
2. **Microservicios con eventos** — `doc-service` (Go) para el ciclo de vida y la SAGA,
   `extraction-worker` (Rust) para el consumo de la cola y la extracción, MinIO para binarios,
   Redis Streams para trabajo y Traefik como gateway.
   - A favor: escalado independiente del worker, aislamiento del parseo, límites de recursos
     por servicio, despliegues y fallos independientes.
   - En contra: consistencia distribuida (SAGA, idempotencia, compensaciones), más superficie
     operativa y necesidad de observabilidad end-to-end.
3. **Mantener el monolito y escalarlo verticalmente** — rechazada: no resuelve el riesgo de un
   PDF hostil ni permite escalar la extracción sin escalar también la API; el costo por request
   de extracción queda mezclado con el de la API.

## Decisión

Se migra a **microservicios orientados a eventos**, con tres unidades desplegables
independientes (`doc-service`, `extraction-worker`, gateway Traefik) y almacenamiento separado
para estado (MongoDB), trabajo (Redis Streams) y binarios (MinIO).

La migración no es un big bang: se hace con el patrón Strangler Fig (ADR-0002). La API
síncrona v1 sigue atendiendo tráfico hasta que el camino v2 tenga paridad de resultado y los
clientes hayan migrado.

## Consecuencias

- **Positivas:** el worker escala y se limita por separado; el parseo de PDF queda aislado;
  cada servicio tiene su propio pipeline y su propio ciclo de fallo; se puede aplicar rate
  limiting en el gateway.
- **Negativas:** aparecen estados intermedios, reintentos, duplicados posibles y la necesidad de
  un reconciliador. Todo documento debe converger a un estado terminal; la consistencia fuerte
  local ya no alcanza.
- **Operativas:** se necesitan logs estructurados con `correlation_id`, métricas por servicio,
  health checks reales (`/readyz` contra dependencias) y runbooks.
- **Deuda consciente:** mTLS interno queda como deuda declarada (se cubre con aislamiento de
  red y el secreto del webhook); el autoscaling real se difiere a una ADR futura.

## Verificación

- El `doc-service` y el `extraction-worker` se despliegan y escalan por separado.
- Un PDF hostil no tumba la API: el worker tiene timeout duro, límites de memoria y `pids_limit`
  (S5-P1-01).
- La API v2 responde `201` y el documento converge a un estado terminal sin intervención manual.
- El E2E de `S1-P4-04` y el replay de S8 se ejecutan sobre el camino nuevo.
