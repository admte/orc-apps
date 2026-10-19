#!/bin/sh
set -eu

# Post-exit hook: the listener is already gone, so GitHub will not refuse the
# removal as busy. A registration made with a personal access token is released
# on APP_STOP_REASON=terminate and on nothing else — a restart or a plain stop
# leaves this node's runner in place, because the same install starts again
# against the same registration. One orc8r minted is orc8r's to remove.

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

# The token param holds either an operator's personal access token or a
# registration orc8r minted for this node, a JSON object. They are told apart by
# shape: a value whose first non-blank character is `{` is the minted credential.
is_minted() {
	trimmed=${1#"${1%%[![:space:]]*}"}
	case "$trimmed" in
	'{'*) return 0 ;;
	*) return 1 ;;
	esac
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

credential=$(token_value 2>/dev/null) || credential=
if [ -z "$credential" ]; then
	note "no credential available; nothing to deregister reason=$reason"
	exit 0
fi

# orc8r minted this registration and removes it itself when the node ends; the
# node holds no credential that could. The identity files go, so a node that
# somehow starts again registers fresh rather than running a removed identity —
# what `config.sh remove` does on the PAT path.
if is_minted "$credential"; then
	note "minted registration; orc8r removes it, nothing to deregister here reason=$reason"
	rm -f "$work_dir/.runner" "$work_dir/.credentials" "$work_dir/.credentials_rsaparams"
	note "removed this node's runner identity files dir=$work_dir"
	exit 0
fi

need curl
need python3
[ -n "${URL:-}" ] || fail "URL is required"
github_token=$credential
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
