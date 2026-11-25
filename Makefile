.PHONY: help up status down test e2e doctor lint
# ARGS="..." se pasa al subcomando: make test ARGS="doc-service --unit"
ARGS ?=

help:
	@echo "Targets:"
	@echo "  help    Show this help"
	@echo "  up      Bring up the QA stack"
	@echo "  status  Show QA stack status"
	@echo "  down    Tear down the QA stack"
	@echo "  test    Run service tests"
	@echo "  e2e     Run end-to-end suites"
	@echo "  doctor  Run QA doctor diagnostics"
	@echo "  lint    Lint infra scripts

ARGS="..." se pasa al subcomando (ej: make test ARGS="doc-service --unit")"

up:
	./scripts/qa/qa.sh up $(ARGS)

status:
	./scripts/qa/qa.sh status $(ARGS)

down:
	./scripts/qa/qa.sh down $(ARGS)

test:
	./scripts/qa/qa.sh test $(ARGS)

e2e:
	./scripts/qa/qa.sh e2e $(ARGS)

doctor:
	./scripts/qa/qa.sh doctor

lint:
	./scripts/qa/qa.sh test infra --lint
