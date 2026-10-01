#!/bin/sh
set -eu

# Removal of the app itself. The runner has already stopped, and the stopped hook
# deleted it from GitLab when the node was terminating; deleting again here is
# best-effort, for the case where the app is taken off a node that keeps running.

fail() {
	echo "gitlab-runner uninstall: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner uninstall: $*" >&2
}

token_value() {
	if [ -n "${TOKEN_FILE:-}" ]; then
		tr -d '\r\n' <"$TOKEN_FILE"
	elif [ -n "${TOKEN:-}" ]; then
		printf '%s' "$TOKEN"
	else
		echo ''
	fi
}

api_call() {
	method=$1
	path=$2
	shift 2
	printf 'header = "PRIVATE-TOKEN: %s"\n' "$gitlab_token" |
		curl -fsSL -K - -X "$method" "$@" "$api/$path"
}

[ -n "${APP_VERSION:-}" ] || fail "APP_VERSION is required"
case "$APP_VERSION" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid APP_VERSION: $APP_VERSION" ;;
esac

root=${GITLAB_RUNNER_INSTALL_ROOT:-/opt/gitlab-runner}
bin_dir=${GITLAB_RUNNER_BIN_DIR:-/usr/local/bin}
prefix="$root/$APP_VERSION"
work_dir=gitlab-runner
config="$work_dir/config.toml"
id_file="$work_dir/runner.id"

deleted=no
if [ -s "$id_file" ]; then
	runner_id=$(cat "$id_file")
	gitlab_token=$(token_value)
	case "${URL:-}" in
	https://*) ;;
	*) gitlab_token='' ;;
	esac
	if [ -z "$gitlab_token" ]; then
		note "no usable URL or access token; leaving the runner in GitLab id=$runner_id"
	else
		rest=${URL#https://}
		api="https://${rest%%/*}/api/v4"
		if api_call DELETE "runners/$runner_id" -o /dev/null; then
			deleted=yes
			note "runner deleted id=$runner_id"
		else
			note "could not delete the runner; removing the install anyway id=$runner_id"
		fi
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
# The app's own state — the runner's authentication token and the job working
# trees — goes only once the last version of the app is gone, so uninstalling one
# of two installed versions does not disarm the one still running.
if rmdir "$root" 2>/dev/null; then
	[ "$deleted" = yes ] && rm -f "$id_file"
	rm -f "$config"
	rm -rf "$work_dir/builds"
	note "removed the last version; cleared the runner configuration"
fi
note "removed version=$APP_VERSION dir=$prefix"
