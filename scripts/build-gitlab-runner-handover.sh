#!/bin/sh
# Builds the gitlab-runner app's hand-over helper from apps/gitlab-runner/handover
# for every Linux architecture the app ships, into apps/gitlab-runner/, where
# `orc build ./apps/gitlab-runner` picks it up. Static and reproducible: no cgo,
# no paths, no build id, no VCS stamp.
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
APP_DIR="$ROOT_DIR/apps/gitlab-runner"

for arch in amd64 arm64; do
	out="$APP_DIR/gitlab-runner-handover-$arch"
	CGO_ENABLED=0 GOOS=linux GOARCH=$arch go build -C "$APP_DIR/handover" \
		-trimpath -buildvcs=false -ldflags='-s -w -buildid=' -o "$out" .
	chmod 0755 "$out"
	echo "built $out"
done
