#!/bin/sh
set -eu

fail() {
	echo "jenkins-agent start: $*" >&2
	exit 1
}

SERVICE_NAME=${SERVICE_NAME:-jenkins-agent}
unit="$SERVICE_NAME.service"
CHECK_PERIOD=${CHECK_PERIOD:-5}

show_service_diagnostics() {
	systemctl status "$unit" --no-pager >&2 || true
	journalctl -u "$unit" --no-pager -n 50 >&2 || true
}

service_runtime() {
	systemctl show "$unit" \
		--property=ActiveState,SubState,Result,NRestarts,ExecMainCode,ExecMainStatus 2>/dev/null || true
}

runtime_field() {
	field=$1
	service_runtime | sed -n "s/^$field=//p" | head -n 1
}

service_healthy() {
	active=$(runtime_field ActiveState)
	sub=$(runtime_field SubState)
	[ "$active" = "active" ] && { [ "$sub" = "running" ] || [ "$sub" = "exited" ]; }
}

command -v systemctl >/dev/null 2>&1 || fail "systemctl is required"

trap 'exit 0' INT TERM

echo "Starting Jenkins agent systemd service ($unit)" >&2
systemctl enable --now "$unit" || {
	show_service_diagnostics
	fail "systemctl enable --now $unit failed"
}

state=$(systemctl is-active "$unit" 2>/dev/null || true)
[ "$state" = "active" ] || {
	show_service_diagnostics
	fail "systemd service $unit is $state"
}

base_restarts=$(runtime_field NRestarts)
[ -n "$base_restarts" ] || base_restarts=0

echo "Jenkins agent service is active ($unit); monitoring health" >&2

while true; do
	sleep "$CHECK_PERIOD"

	current_restarts=$(runtime_field NRestarts)
	[ -n "$current_restarts" ] || current_restarts=0
	if [ "$current_restarts" -gt "$base_restarts" ]; then
		show_service_diagnostics
		fail "systemd service $unit restarted itself (NRestarts $base_restarts -> $current_restarts)"
	fi

	if service_healthy; then
		continue
	fi

	show_service_diagnostics
	fail "systemd service $unit became unhealthy (active_state=$(runtime_field ActiveState), substate=$(runtime_field SubState), result=$(runtime_field Result))"
done
