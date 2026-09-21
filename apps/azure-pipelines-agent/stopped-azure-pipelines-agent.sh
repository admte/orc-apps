#!/bin/sh
set -eu

# Post-exit hook: the agent host is already gone, so Azure DevOps will not refuse
# the removal as busy. The registration is released on APP_STOP_REASON=terminate
# and on nothing else — a restart or a plain stop leaves this node's agent in
# place, because the same install starts again against the same registration and
# only needs enabling.

SERVICE_USER=${SERVICE_USER:-azagent}
ATTEMPTS=${ATTEMPTS:-3}
RETRY_INTERVAL=${RETRY_INTERVAL:-5}

fail() {
	echo "azure-pipelines-agent stopped: $*" >&2
	exit 1
}

note() {
	echo "azure-pipelines-agent stopped: $*" >&2
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

# config.sh refuses to run as root; drop to the account that owns the agent
# directory, the same way install and start do. setpriv, never su or runuser.
as_service_user() {
	if [ "$(id -u)" -eq 0 ] && id "$SERVICE_USER" >/dev/null 2>&1; then
		setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
			env HOME="$work_dir" "$@"
	else
		env HOME="$work_dir" "$@"
	fi
}

reason=${APP_STOP_REASON:-exit}
if [ "$reason" != terminate ]; then
	note "keeping the agent registration reason=$reason"
	exit 0
fi

work_dir=azure-pipelines-agent
if [ ! -x "$work_dir/config.sh" ]; then
	note "no install found; nothing to deregister dir=$work_dir"
	exit 0
fi
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
if [ ! -f "$work_dir/.agent" ]; then
	note "no registration found; nothing to deregister dir=$work_dir"
	exit 0
fi

azp_token=$(token_value)
[ -n "$azp_token" ] || fail "TOKEN_FILE or TOKEN is required"

cd "$work_dir"
attempt=1
while :; do
	note "deregistering the agent reason=$reason attempt=$attempt/$ATTEMPTS"
	# The PAT goes through the environment rather than a --token flag, so it stays
	# out of the process list.
	if VSTS_AGENT_INPUT_TOKEN="$azp_token" \
		as_service_user ./config.sh remove --unattended --auth pat; then
		note "agent deregistered reason=$reason"
		exit 0
	fi
	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		fail "failed to deregister the agent after $ATTEMPTS attempts"
	fi
	attempt=$((attempt + 1))
	sleep "$RETRY_INTERVAL"
done
