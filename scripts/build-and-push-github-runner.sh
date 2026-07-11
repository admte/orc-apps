#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT_DIR=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

ORC_BIN=${ORC:-}
if [ -z "$ORC_BIN" ]; then
	if [ -x "$ROOT_DIR/Build/orc" ]; then
		ORC_BIN="$ROOT_DIR/Build/orc"
	else
		ORC_BIN="$ROOT_DIR/orc"
	fi
fi

if [ ! -x "$ORC_BIN" ]; then
	echo "orc CLI not found. Run ./scripts/install.sh or set ORC=/path/to/orc" >&2
	exit 1
fi

"$ORC_BIN" build "$ROOT_DIR/apps/github-runner" --push "$@"
