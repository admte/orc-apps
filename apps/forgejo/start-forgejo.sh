#!/bin/sh
set -eu

# Start phase: the packaged script that stands in for an inline `start.command`. A start
# command that resolves — from config or, as here, from a packaged script — together with
# `start.service: forgejo` is what selects runtime-managed service mode, so the node
# writes the service definition itself and this package ships no unit file and enables
# nothing for boot.
#
# setpriv (never su or runuser) drops to the forgejo account inside the same session, so
# the server stays the service's own process and the stop signal reaches it. Every step
# execs: this script becomes setpriv, which becomes forgejo, so the service's main pid is
# the server itself and SIGTERM lands on it.

bin_dir=${FORGEJO_BIN_DIR:-/usr/local/bin}
data_dir=${FORGEJO_DATA_DIR:-/var/lib/forgejo}
service_user=${FORGEJO_SERVICE_USER:-forgejo}
config_path="$data_dir/custom/conf/app.ini"

fail() {
	echo "forgejo start: $*" >&2
	exit 1
}

# The symlink, not the versioned path: switching versions repoints it, and the service
# picks the new binary up on its next restart without the service definition changing.
[ -x "$bin_dir/forgejo" ] || fail "no install found; install must run first path=$bin_dir/forgejo"
id "$service_user" >/dev/null 2>&1 || fail "service user $service_user does not exist"

# The layout is ensured HERE, not only in install, and this is not belt-and-braces.
#
# /var/lib/forgejo is a declared persisted path: the platform grafts its own volume onto
# it. Install runs while the pool image is being baked, so the directories it creates
# under that path end up on the OS disk and are then masked by the volume mounted over
# them — a node rebuilt from the image finds the tree empty ("App data restored: 0 files")
# and Forgejo, running unprivileged, cannot create the first directory itself.
#
# Start runs on every boot, after the volume is in place, and still as root. So this is
# the only phase that can be trusted to shape a persisted tree.
#
# Ownership is applied recursively, and that is not caution either. A restore puts the
# files back but not necessarily under the account the app runs as: after the first
# rebuild Forgejo read its own restored app.ini and got "permission denied". Only the
# owner is changed — no mode is touched, nothing is created or removed inside — so a
# restored instance keeps its content exactly as it was.
ensure_layout() {
	mkdir -p "$data_dir/custom/conf" "$data_dir/data" "$data_dir/log"
	chown -R "$service_user:$service_user" "$data_dir"
	chmod 0750 "$data_dir"
}

ensure_layout

if [ -f "$config_path" ]; then
	echo "forgejo start: using the existing configuration path=$config_path" >&2
else
	echo "forgejo start: no configuration yet; Forgejo will serve its setup page on first visit" >&2
fi

# The account has no home directory, so HOME points at the data directory it owns.
# FORGEJO_WORK_DIR keeps every path Forgejo derives — repositories, database, logs —
# inside the one tree the platform persists.
exec setpriv --reuid="$service_user" --regid="$service_user" --init-groups \
	env HOME="$data_dir" USER="$service_user" FORGEJO_WORK_DIR="$data_dir" \
	"$bin_dir/forgejo" web --config "$config_path" --port 3000
