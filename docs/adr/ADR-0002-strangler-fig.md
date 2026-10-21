# ADR-0002 — Migración con Strangler Fig y no con big bang

- **Estado:** Propuesto (a aceptar en la revisión de arquitectura de S0)
- **Fecha:** Semana 0 (S0-P4-03)
- **Owner:** P4
- **Revisada por:** P1, P2, P3
- **Contexto:** `SPEC.md` v2.1 §2, §13 · `pasos-iniciales.md` §4, §11.2 · `S0-P4-01`, `S0-P4-07`

## Contexto

El monolito FastAPI está en uso y tiene clientes reales. La migración debe permitir convivir el
camino viejo y el nuevo durante un periodo acotado, medir el tráfico por ruta y apagar el
monolito solo cuando exista evidencia de que ya no recibe peticiones.

Un corte big bang obligaría a migrar a todos los clientes en una fecha única, sin red de
seguridad y sin forma de comparar resultados con tráfico real. El costo de un error sería una
caída total, no una degradación controlada.

## Opciones consideradas

1. **Big bang** — apagar el monolito y encender los servicios nuevos en una ventana.
   - A favor: no hay que mantener dos caminos ni convivir con dos contratos.
   - En contra: no hay reversión gradual; un fallo afecta al 100 % del tráfico; no se puede
     comparar el resultado nuevo contra el viejo con datos reales; la migración de clientes se
     vuelve un requisito previo y no un proceso acompañado.
2. **Strangler Fig** — Traefik enruta primero una ruta al camino nuevo, se observa, se amplía la
   cobertura y el monolito se apaga cuando el tráfico legacy es cero.
   - A favor: reversión en segundos cambiando el peso/routing; comparación de resultados con
     tráfico real; los clientes migran por ruta y con fecha límite.
   - En contra: hay dos contratos y dos caminos durante la transición; hay que instrumentar el
     tráfico legacy; el equipo debe resistir la tentación de agregar funcionalidad al camino
     viejo.
3. **Fachada síncrona permanente sobre v2** — el monolito sigue expuesto y por dentro llama al
   camino nuevo.
   - A favor: los clientes no cambian.
   - En contra: congela el contrato viejo como código permanente, agrega una capa de traducción
     que nadie pidió y mantiene vivo el monolito indefinidamente. Descartada en ADR-0018.

## Decisión

Se adopta **Strangler Fig**:

1. Traefik enruta `/api/v2/documents/*` al camino nuevo y `/*` al monolito.
2. Cada ruta del inventario (`S0-P4-01`) tiene destino explícito; no hay `catch-all` sin
   decisión.
3. La migración de clientes se hace con fecha límite (ADR-0018), no con una fachada permanente.
4. El apagado del monolito exige **0 tráfico a rutas legacy durante 7 días consecutivos**,
   medido en los access logs de Traefik.
5. El camino viejo entra en modo deprecado (`Deprecation`/`Sunset`) antes del corte, sin
   funcionalidad nueva.

## Consecuencias

- **Positivas:** la reversión es un cambio de regla de ruteo, no un redespliegue completo; se
  puede hacer canary por peso; la paridad se verifica con tráfico real y con el replay de S8.
- **Negativas:** durante la transición hay dos caminos, dos contratos y dos formas de fallar. La
  observabilidad y el inventario de clientes son obligatorios, no opcionales.
- **Regla de disciplina:** toda funcionalidad nueva va al camino v2. El monolito solo recibe
  correcciones de seguridad o bugs bloqueantes, y cada una se registra.
- **Condición de cierre:** sin inventario de clientes con responsable y sin 7 días de tráfico
  legacy cero, no se apaga el monolito. La fecha límite se acuerda por escrito con el negocio
  (ADR-0018).

## Verificación

- Traefik enruta `/api/v2/documents/*` al `doc-service` y el resto al monolito.
- Los access logs permiten medir tráfico por ruta legacy y por cliente.
- El replay de S8 compara texto extraído normalizado, no respuestas HTTP.
- El canary de S8/S10 puede revertirse a 0 % en segundos.
