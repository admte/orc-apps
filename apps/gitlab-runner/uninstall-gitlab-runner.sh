#!/bin/sh
set -eu

# Removal of the app itself. The runner has already stopped, and the stopped hook
# released the registration when the node was terminating; releasing again here is
# best-effort, for the case where the app is taken off a node that keeps running.

note() {
	echo "gitlab-runner uninstall: $*" >&2
}

[ -n "${APP_VERSION:-}" ] || {
	echo "gitlab-runner uninstall: APP_VERSION is required" >&2
	exit 1
}
case "$APP_VERSION" in
'' | *[!0-9.]* | .* | *..* | *.)
	echo "gitlab-runner uninstall: invalid APP_VERSION: $APP_VERSION" >&2
	exit 1
	;;
esac

root=${GITLAB_RUNNER_INSTALL_ROOT:-/opt/gitlab-runner}
bin_dir=${GITLAB_RUNNER_BIN_DIR:-/usr/local/bin}
prefix="$root/$APP_VERSION"
work_dir=gitlab-runner
config="$work_dir/config.toml"

if [ -x "$prefix/gitlab-runner" ] && [ -f "$config" ]; then
	config=$(CDPATH= cd -- "$work_dir" && pwd)/config.toml
	if "$prefix/gitlab-runner" unregister --config "$config" --all-runners; then
		note "runner unregistered"
	else
		note "could not unregister; removing the install anyway"
	fi
fi

# Only an exposure that still points into this version's own tree is ours to
# remove: after an upgrade it belongs to the version that replaced this one.
target=$(readlink "$bin_dir/gitlab-runner" 2>/dev/null || true)
case "$target" in
"$prefix"/*) rm -f "$bin_dir/gitlab-runner" ;;
esac
current_target=$(readlink "$root/current" 2>/dev/null || true)
[ "$current_target" != "$prefix" ] || rm -f "$root/current"

rm -rf "$prefix"
rmdir "$root" 2>/dev/null || true
note "removed version=$APP_VERSION dir=$prefix"
