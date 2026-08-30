#!/bin/sh
set -eu

# Post-exit hook: the listener is already gone, so GitHub will not refuse the
# removal as busy. The registration is released on APP_STOP_REASON=terminate and
# on nothing else — a restart or a plain stop leaves this node's runner in place,
# because the same install starts again against the same registration.

SERVICE_USER=${SERVICE_USER:-ghrunner}
ATTEMPTS=${ATTEMPTS:-3}
RETRY_INTERVAL=${RETRY_INTERVAL:-5}

fail() {
	echo "github-runner stopped: $*" >&2
	exit 1
}

note() {
	echo "github-runner stopped: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

token_value() {
	if [ -n "${TOKEN_FILE:-}" ]; then
		tr -d '\r\n' <"$TOKEN_FILE"
	elif [ -n "${TOKEN:-}" ]; then
		printf '%s' "$TOKEN"
	else
		fail "TOKEN_FILE or TOKEN is required"
	fi
}

github_api_path() {
	url=${URL:-}
	case "$url" in
	https://github.com/*) ;;
	*) fail "URL must start with https://github.com/" ;;
	esac
	path=${url#https://github.com/}
	path=${path%.git}
	path=${path%/}
	owner=${path%%/*}
	rest=${path#*/}
	[ -n "$owner" ] || fail "GitHub owner is required"
	if [ "$rest" != "$path" ] && [ -n "$rest" ]; then
		printf 'repos/%s/%s' "$owner" "$rest"
	else
		printf 'orgs/%s' "$owner"
	fi
}

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

# config.sh refuses to run as root; drop to the account that owns the runner
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
	note "keeping the runner registration reason=$reason"
	exit 0
fi

work_dir=github-runner
if [ ! -x "$work_dir/config.sh" ]; then
	note "no install found; nothing to deregister dir=$work_dir"
	exit 0
fi
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

need curl
need python3
[ -n "${URL:-}" ] || fail "URL is required"
github_token=$(token_value)
api_path=$(github_api_path)

cd "$work_dir"
attempt=1
while :; do
	note "deregistering the runner reason=$reason attempt=$attempt/$ATTEMPTS"
	# A remove token is short-lived, so it is minted per attempt rather than reused.
	if remove_json=$(curl -fsSL -X POST \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$api_path/actions/runners/remove-token" 2>/dev/null) &&
		remove_token=$(printf '%s' "$remove_json" | json_field token) &&
		[ -n "$remove_token" ] &&
		as_service_user ./config.sh remove --token "$remove_token"; then
		note "runner deregistered reason=$reason"
		exit 0
	fi

	if [ "$attempt" -ge "$ATTEMPTS" ]; then
		fail "failed to deregister the runner after $ATTEMPTS attempts"
	fi
	attempt=$((attempt + 1))
	sleep "$RETRY_INTERVAL"
done
