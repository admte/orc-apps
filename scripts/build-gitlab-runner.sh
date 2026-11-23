#!/bin/sh
# Builds the gitlab-runner app: the hand-over helper first, then the package, so
# the package never carries a stale helper. Extra arguments go to `orc build`:
#
#   ./scripts/build-gitlab-runner.sh --push
#   ./scripts/build-gitlab-runner.sh --output ./gitlab-runner-oci
set -eu

ROOT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$ROOT_DIR/scripts/build-gitlab-runner-handover.sh"
exec "$ROOT_DIR/orc" build "$ROOT_DIR/apps/gitlab-runner" "$@"
