# ADR-0018 — Compatibilidad y migración de clientes al contrato asíncrono v2

- **Estado:** Propuesto — **BLOQUEADO** por falta de inventario con uso real y fecha firmada por el negocio
- **Fecha:** Semana 0 (S0-P4-07)
- **Owner:** P4
- **Revisada por:** P1, P2, P3 y el negocio
- **Contexto:** `SPEC.md` v2.1 §13 · `pasos-iniciales.md` §11.2, §19 · `S0-P4-01`, `S0-P4-07`

## Contexto

El monolito expone un contrato síncrono v1: el cliente sube el PDF a `POST /pdf/process` y recibe
el `.txt` en la misma respuesta. El camino nuevo v2 es asíncrono: `POST /api/v2/documents` devuelve
`202` con una URL prefirmada, el cliente sube el PDF directo a MinIO, espera el webhook, consulta
el estado y descarga el `.txt` con una URL prefirmada.

Los clientes actuales no son infinitos ni desconocidos: el negocio los conoce. La decisión no es
"cómo evitar que cambien", sino **cómo acompañarlos a cambiar sin congelar el contrato viejo para
siempre**.

## Opciones consideradas

1. **Fachada síncrona que envuelve a v2** — mantener `POST /pdf/process` como fachada que crea el
   documento, sube el archivo, hace polling y devuelve el `.txt`.
   - A favor: los clientes no cambian su integración.
   - En contra: congela el contrato viejo como código permanente, agrega una capa de traducción y
     mantiene vivo el monolito indefinidamente; el negocio nunca termina de migrar. **Descartada.**
2. **Migración de clientes con fecha límite** — cada cliente migra a v2 antes de una fecha
   acordada; el camino viejo queda disponible y deprecado hasta esa fecha.
   - A favor: el contrato viejo desaparece, el equipo acompaña cliente por cliente y la fecha es
     explícita. El inventario es acotado y conocido.
   - En contra: requiere coordinación con el negocio y disciplina de comunicación; algunos clientes
     pueden necesitar una excepción.
   - **Elegida.**
3. **El monolito sigue para el flujo síncrono y v2 solo para clientes nuevos** — convivencia
   permanente de ambos caminos.
   - A favor: cero cambios para los clientes actuales.
   - En contra: el camino caliente queda en el monolito para siempre, con dos sistemas que mantener
     y dos formas de fallar. **Descartada.**

## Decisión

Se adopta **(b) migración de clientes con fecha límite**:

- Cada cliente del inventario tiene responsable, rutas usadas, uso real medido en access logs y
  fecha de migración comprometida por escrito.
- El camino v1 queda disponible hasta la fecha límite, en **modo deprecado**: cabeceras
  `Deprecation`/`Sunset`, sin funcionalidad nueva y sin cambios de comportamiento.
- Los clientes que no migren entran como **excepción firmada**, con impacto y nueva fecha; no se
  dejan como deuda invisible.
- El apagado del enrutamiento legacy exige **0 tráfico a rutas legacy durante 7 días
  consecutivos**, medido en los access logs de Traefik.

## Consecuencias

- **Positivas:** el contrato v1 se puede apagar con evidencia; no queda una fachada permanente; el
  negocio conoce la fecha y el costo de no migrar.
- **Negativas:** durante la transición hay dos contratos; el equipo debe medir y comunicar; los
  clientes con excepción extienden la vida del monolito.
- **Operativas:** los access logs de Traefik son obligatorios; el inventario se revisa
  semanalmente; cada excepción tiene owner y fecha.
- **Condición de reversión:** si un cliente no puede migrar, se alarga la ventana con una decisión
  registrada, **sin apagar el monolito**. La reversión del corte es cambiar el peso/routing, no un
  redespliegue.

## Plan de comunicación

| Paso | Responsable | Salida |
|---|---|---|
| 1. Publicar inventario con uso real, responsable y ruta | P4 | Tabla viva revisada semanalmente |
| 2. Comunicar la fecha límite y qué cambia en su integración (`202`, subida directa, consulta, descarga) | P4 + negocio | Comunicación escrita con acuse |
| 3. Acompañar la migración por cliente | P4 + P2 | Cliente migrado y verificado |
| 4. Medir semanalmente el tráfico legacy | P4 | Serie semanal publicada |
| 5. Al llegar la fecha: apagar el routing legacy y verificar en logs | P1 + P4 | 0 tráfico legacy |
| 6. Inventariar excepciones | P4 | Registro con owner e impacto |

## Verificación

- [ ] Inventario de clientes con uso real medido (no estimado), responsable y ruta.
- [ ] Fecha límite acordada **por escrito con el negocio**.
- [ ] Camino v1 en modo deprecado con `Deprecation`/`Sunset`.
- [ ] 0 tráfico a rutas legacy durante 7 días consecutivos antes del apagado.
- [ ] Excepciones firmadas, con impacto y nueva fecha.

## Bloqueo actual

El inventario de clientes (`platform-services/docs/clientes.md`) está incompleto: faltan access
logs reales y la firma del negocio. Hasta resolverlo, esta ADR **no se acepta** y `S0-P4-07` queda
`BLOQUEADA`. No se inventa una fecha límite.
