#!/bin/sh
set -eu

# Post-exit hook: the runner is already gone, so GitLab will not refuse the
# removal as busy. The registration is released on APP_STOP_REASON=terminate and
# on nothing else — a restart or a plain stop leaves this node's runner manager in
# place, because the same install starts again against the same config.toml.

ATTEMPTS=${ATTEMPTS:-3}
RETRY_INTERVAL=${RETRY_INTERVAL:-5}

fail() {
	echo "gitlab-runner stopped: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner stopped: $*" >&2
}

reason=${APP_STOP_REASON:-exit}
if [ "$reason" != terminate ]; then
	note "keeping the runner registration reason=$reason"
	exit 0
fi

work_dir=gitlab-runner
config="$work_dir/config.toml"
if [ ! -f "$config" ]; then
	note "no registration found; nothing to release config=$config"
	exit 0
fi
config=$(CDPATH= cd -- "$work_dir" && pwd)/config.toml

command -v gitlab-runner >/dev/null 2>&1 || {
	note "the runner binary is gone; nothing to release"
	exit 0
}

attempt=1
while :; do
	note "unregistering the runner reason=$reason attempt=$attempt/$ATTEMPTS"
	if gitlab-runner unregister --config "$config" --all-runners; then
		note "runner unregistered reason=$reason"
		exit 0
	fi
	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		fail "failed to unregister the runner after $ATTEMPTS attempts"
	fi
	attempt=$((attempt + 1))
	sleep "$RETRY_INTERVAL"
done
