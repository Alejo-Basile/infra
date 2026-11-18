# Cierre S11-P1-C26

## Entregables
| Entregable | Archivo |
| --- | --- |
| Runbook | infra/runbooks/consul.md |
| Snapshot script | infra/scripts/consul-snapshot.sh |
| Snapshot evidence | infra/docs/evidencias/S11/S11-P1-C26-snapshot.txt |
| Trivy evidence | infra/docs/evidencias/S11/S11-P1-C26-trivy.txt |
| Gitleaks evidence | infra/docs/evidencias/S11/S11-P1-C26-gitleaks.txt |

## DoD
| Criterio | Evidencia | Estado |
| --- | --- | --- |
| Runbook 10 secciones | infra/runbooks/consul.md | PASS |
| Snapshot/restore ensayado fuera del volumen real | S11-P1-C26-snapshot.txt | PASS |
| Trivy sin CRITICAL/HIGH o excepción | S11-P1-C26-trivy.txt | EXCEPTION |
| Gitleaks limpio o documentado | S11-P1-C26-gitleaks.txt | EXCEPTION |
| Checklist §11 | docs/plan-S11-P1-consul.md | PARTIAL |

## Excepciones aceptadas
- Trivy: CRITICAL/HIGH en imágenes fijadas; owner P1; vencimiento 2026-12-31; mitigación actualizar imagen upstream; no se editó para pasar.
- Gitleaks: 2 private-key en consul_ca_key.pem y consul_server_key.pem (keys de laboratorio); infra/.gitignore ignora secrets/.

## Items §11 no marcados
- §0.2 contrato OCR-worker (falta).
- Varios items sin evidencia concreta (falta).

## Diferido
- Cluster HA, mTLS agentes/server, HPA/KEDA, consulCatalog routing.yml (§0 y ADR-0021).
EOF