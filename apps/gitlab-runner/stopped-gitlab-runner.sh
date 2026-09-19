#!/bin/sh
set -eu

# Post-exit hook: the runner process is already gone. The runner is deleted from
# GitLab on APP_STOP_REASON=terminate and on nothing else — a restart or a plain
# stop leaves it in place, because the same install starts again against the same
# config.toml and only needs resuming.
#
# Order matters. The runner is deleted through the API first, while config.toml
# still holds the only other copy of its authentication token; `unregister` and
# the removal of config.toml come after, once there is nothing left to reach.
# Deleting the local state last is also what makes the next start create a fresh
# runner instead of coming up against one GitLab no longer has: a node in that
# state looks healthy and is never given another job.
#
# `unregister` alone would not do: a runner created through the API (which is how
# start-gitlab-runner.sh creates it) survives it — unregister removes this node's
# runner manager, and the runner itself stays behind.

ATTEMPTS=${ATTEMPTS:-3}
RETRY_INTERVAL=${RETRY_INTERVAL:-5}

fail() {
	echo "gitlab-runner stopped: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner stopped: $*" >&2
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

reason=${APP_STOP_REASON:-exit}
if [ "$reason" != terminate ]; then
	note "keeping the runner reason=$reason"
	exit 0
fi

work_dir=gitlab-runner
config="$work_dir/config.toml"
id_file="$work_dir/runner.id"
if [ ! -s "$id_file" ]; then
	note "no runner recorded; nothing to delete"
	exit 0
fi
runner_id=$(cat "$id_file")

command -v curl >/dev/null 2>&1 || fail "curl is required"
[ -n "${URL:-}" ] || fail "URL is required"
case "$URL" in
https://*) ;;
*) fail "URL must start with https://" ;;
esac
gitlab_token=$(token_value)
[ -n "$gitlab_token" ] || fail "TOKEN_FILE or TOKEN is required"
rest=${URL#https://}
api="https://${rest%%/*}/api/v4"

attempt=1
while :; do
	note "deleting the runner reason=$reason id=$runner_id attempt=$attempt/$ATTEMPTS"
	if api_call DELETE "runners/$runner_id" -o /dev/null; then
		break
	fi
	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		fail "failed to delete the runner after $ATTEMPTS attempts id=$runner_id"
	fi
	attempt=$((attempt + 1))
	sleep "$RETRY_INTERVAL"
done

# The runner is gone from GitLab, so the local state is dead weight; clearing it
# is what lets the next start create a new one. unregister is best-effort — the
# removal below is what the next start actually reads.
runner=${GITLAB_RUNNER_INSTALL_ROOT:-/opt/gitlab-runner}
if [ -n "${APP_VERSION:-}" ] && [ -x "$runner/$APP_VERSION/gitlab-runner" ]; then
	runner="$runner/$APP_VERSION/gitlab-runner"
else
	runner="$runner/current/gitlab-runner"
fi
if [ -x "$runner" ] && [ -f "$config" ]; then
	"$runner" unregister --config "$(CDPATH= cd -- "$work_dir" && pwd)/config.toml" --all-runners ||
		note "unregister failed; removing the local configuration anyway id=$runner_id"
fi
rm -f "$config" "$id_file"
note "runner deleted reason=$reason id=$runner_id"
