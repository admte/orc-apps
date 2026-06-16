export GOTOOLCHAIN ?= go1.25.0

ORC_ARTIFACT ?= ../orc-artifact/Build/orc-artifact
REGISTRY ?= ghcr.io/admte
SHELL_VERSION ?= 1.0.1
SHELL_REF ?= $(REGISTRY)/shell:$(SHELL_VERSION),default
APT_VERSION ?= 1.0.0
APT_REF ?= $(REGISTRY)/apt:$(APT_VERSION),default

.PHONY: test validate tidy push-shell push-apt
all: test

test:
	go test -race ./...

validate: test

tidy:
	go mod tidy

push-shell:
	$(ORC_ARTIFACT) push -platform linux/amd64 "$(SHELL_REF)" apps/shell/linux/app.config.v1.json
	$(ORC_ARTIFACT) push -platform windows/amd64 "$(SHELL_REF)" apps/shell/windows/app.config.v1.json

push-apt:
	$(ORC_ARTIFACT) push -platform linux/amd64 "$(APT_REF)" \
		apps/apt/linux/app.config.v1.json \
		apps/apt/linux/install-apt.sh \
		apps/apt/linux/start-apt.sh
