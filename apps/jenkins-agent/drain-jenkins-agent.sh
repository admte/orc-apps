#!/bin/sh
set -eu

SERVICE_NAME=${SERVICE_NAME:-jenkins-agent}
unit="$SERVICE_NAME.service"

if ! command -v systemctl >/dev/null 2>&1; then
	echo "jenkins-agent drain: systemctl not found; nothing to stop" >&2
	exit 0
fi

if ! systemctl cat "$unit" >/dev/null 2>&1; then
	echo "jenkins-agent drain: $unit not installed; nothing to stop" >&2
	exit 0
fi

echo "Stopping Jenkins agent systemd service ($unit)" >&2
systemctl stop "$unit" || true
