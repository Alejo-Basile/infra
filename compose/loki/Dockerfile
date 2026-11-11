# Add a static HTTP probe to the upstream distroless Loki image without changing its runtime.
FROM golang:1.26-alpine@sha256:2173d702003b1a8d17b844191acaeb36e94de46f6cabf2cb27370e151bbce5aa AS probe
WORKDIR /src
COPY healthcheck.go .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /loki-healthcheck ./healthcheck.go

FROM grafana/loki:3.6.20@sha256:be040ec94865dabe4821ce1c0f109452bd4b5acb566ae376672696eb43caedb7

COPY --from=probe /loki-healthcheck /usr/local/bin/loki-healthcheck
USER 10001
