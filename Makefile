export GOTOOLCHAIN ?= go1.25.0

.PHONY: test validate tidy
all: test

test:
	go test -race ./...

validate: test

tidy:
	go mod tidy
