#!/bin/sh
set -eu

# Runs after the listener has exited, so GitHub will not refuse the removal as
# busy. A registration made with a personal access token is released on stop
# reason `terminate` and on nothing else — a restart or a plain stop leaves this
# machine's runner in place, because the same install starts again against the
# same registration. A JSON registration carries no credential that could remove
# it, so only its identity files here are dropped. A just-in-time runner is removed
# by GitHub after its job, so for it there is nothing to do here at all.

usage() {
	cat <<'USAGE'
Usage: stopped-github-runner.sh [--url=URL] [--token-file=PATH] [--stop-reason=REASON]
                                [--service-user=NAME] [--attempts=N]
                                [--retry-interval=SECONDS]

Runs after the listener has exited. On --stop-reason=terminate it releases the
runner registration (personal access token) or drops this machine's runner
identity files (a JSON registration); on any other reason it keeps both. A
just-in-time registration has nothing to release: GitHub removes the runner.

  --url=URL                 repository or organization URL (personal access token)
  --token-file=PATH         file holding a personal access token or a runner
                            registration as a JSON object
  --stop-reason=REASON      why the runner stopped (default: exit)
  --service-user=NAME       account that owns the runner (default: ghrunner)
  --attempts=N              deregistration attempts (default: 3)
  --retry-interval=SECONDS  pause between attempts (default: 5)
  --help                    show this help
USAGE
}

fail() {
	echo "github-runner stopped: $*" >&2
	exit 1
}

usage_error() {
	echo "github-runner stopped: $*" >&2
	usage >&2
	exit 2
}

repo_url=
token_file=
reason='exit'
service_user=ghrunner
attempts=3
retry_interval=5
for arg; do
	case $arg in
	--url=*) repo_url=${arg#--url=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--stop-reason=*) reason=${arg#--stop-reason=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--attempts=*) attempts=${arg#--attempts=} ;;
	--retry-interval=*) retry_interval=${arg#--retry-interval=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$reason" ] || reason='exit'
[ -n "$service_user" ] || usage_error "--service-user must not be empty"
case $attempts in
'' | *[!0-9]* | 0) usage_error "--attempts must be a positive whole number" ;;
esac
case $retry_interval in
'' | *[!0-9]*) usage_error "--retry-interval must be a whole number of seconds" ;;
esac

# Progress to stdout; warnings and errors to stderr.
note() {
	echo "github-runner stopped: $*"
}

warn() {
	echo "github-runner stopped: warning: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

token_value() {
	[ -n "$token_file" ] || fail "--token-file is required"
	tr -d '\r\n' <"$token_file"
}

# The token file holds either a personal access token or a runner registration
# supplied as a JSON object. They are told apart by shape: a value whose first
# non-blank character is `{` is the JSON registration.
is_minted() {
	trimmed=${1#"${1%%[![:space:]]*}"}
	case "$trimmed" in
	'{'*) return 0 ;;
	*) return 1 ;;
	esac
}

github_api_path() {
	case "$repo_url" in
	https://github.com/*) ;;
	*) fail "--url must start with https://github.com/" ;;
	esac
	path=${repo_url#https://github.com/}
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

# Prints the mode of the JSON registration on stdin, or nothing when it has none.
registration_mode() {
	python3 -c '
import json, sys
cred = json.load(sys.stdin)
mode = cred.get("mode") if isinstance(cred, dict) else None
print(mode if isinstance(mode, str) else "")
' 2>/dev/null || true
}

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1"
}

# config.sh refuses to run as root; drop to the account that owns the runner
# directory, the same way install and start do. setpriv, never su or runuser.
as_service_user() {
	if [ "$(id -u)" -eq 0 ] && id "$service_user" >/dev/null 2>&1; then
		setpriv --reuid="$service_user" --regid="$service_user" --init-groups \
			env HOME="$work_dir" "$@"
	else
		env HOME="$work_dir" "$@"
	fi
}

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

# A JSON registration comes with no credential that could remove the runner from
# GitHub, so that is left to whoever holds one. The identity files go, so an
# install that starts again registers fresh rather than running a removed
# identity — what `config.sh remove` does on the PAT path.
if is_minted "$credential"; then
	if [ "$(printf '%s' "$credential" | registration_mode)" = jit ]; then
		note "just-in-time registration; GitHub removes the runner after its job, nothing to deregister reason=$reason"
		exit 0
	fi
	note "JSON registration; no credential here can remove it, nothing to deregister here reason=$reason"
	rm -f "$work_dir/.runner" "$work_dir/.credentials" "$work_dir/.credentials_rsaparams"
	note "removed this machine's runner identity files dir=$work_dir"
	exit 0
fi

# config.sh writes `.runner` when it registers and deletes it when the runner is
# removed, so without one there is no registration here to release. An ephemeral
# runner leaves none once its job is done: GitHub has removed it already.
if [ ! -f "$work_dir/.runner" ]; then
	note "no registration record; nothing to deregister file=$work_dir/.runner reason=$reason"
	exit 0
fi

need curl
need python3
[ -n "$repo_url" ] || fail "--url is required"
github_token=$credential
api_path=$(github_api_path)

cd "$work_dir"
attempt=1
while :; do
	note "deregistering the runner reason=$reason attempt=$attempt/$attempts"
	# A remove token is short-lived, so it is requested per attempt rather than
	# reused.
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

	if [ "$attempt" -ge "$attempts" ]; then
		fail "failed to deregister the runner after $attempts attempts"
	fi
	warn "deregistration attempt failed; retrying attempt=$attempt/$attempts"
	attempt=$((attempt + 1))
	sleep "$retry_interval"
done
