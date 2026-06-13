export GOTOOLCHAIN ?= go1.25.0

ORC_ARTIFACT ?= ../orc-artifact/Build/orc-artifact
REGISTRY ?= ghcr.io/admte
SHELL_VERSION ?= 1.0.1
SHELL_REF ?= $(REGISTRY)/shell:$(SHELL_VERSION),default

.PHONY: test validate tidy push-shell
all: test

test:
	go test -race ./...

validate: test

tidy:
	go mod tidy

push-shell:
	$(ORC_ARTIFACT) push -platform linux/amd64 "$(SHELL_REF)" apps/shell/linux/app.config.v1.json
	$(ORC_ARTIFACT) push -platform windows/amd64 "$(SHELL_REF)" apps/shell/windows/app.config.v1.json
