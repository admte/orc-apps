#!/bin/sh
set -eu

# Quiesce hook: the listener is still running and may be mid-job. With a personal
# access token, take the pool label off the runner so the queue stops routing work
# here; in either mode, wait for the worker that is already running to finish,
# then exit 0. Stopping the listener is the runtime's next step; deregistering is
# stopped-github-runner.sh's, and only when the node is going away for good.

# Kept under the 1h stop.timeout so the wait ends with a message of its own
# rather than being cut off mid-poll.
JOB_TIMEOUT=${JOB_TIMEOUT:-3540}
POLL_INTERVAL=${POLL_INTERVAL:-10}

fail() {
	echo "github-runner stop: $*" >&2
	exit 1
}

note() {
	echo "github-runner stop: $*" >&2
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

github_get() {
	curl -fsSL \
		-H "Accept: application/vnd.github+json" \
		-H "Authorization: token $github_token" \
		"https://api.github.com/$1"
}

# Prints the numeric id of the runner registered under $1, or nothing.
runner_id_on_page() {
	python3 -c '
import json, sys
name = sys.argv[1]
for runner in json.load(sys.stdin).get("runners", []):
    if runner.get("name") == name:
        print(runner.get("id", ""))
        break
' "$1"
}

runner_page_count() {
	python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("runners", [])))'
}

# The API pages at 100; an org can register far more runners than that, so walk
# pages until one comes back short or the name is found.
find_runner_id() {
	page=1
	while [ "$page" -le 20 ]; do
		body=$(github_get "$api_path/actions/runners?per_page=100&page=$page") || return 1
		id=$(printf '%s' "$body" | runner_id_on_page "$runner_name")
		if [ -n "$id" ]; then
			printf '%s' "$id"
			return 0
		fi
		[ "$(printf '%s' "$body" | runner_page_count)" -eq 100 ] || return 0
		page=$((page + 1))
	done
	return 0
}

# A job runs in Runner.Worker, a child the listener spawns out of its own
# directory; no worker means no job in flight.
worker_running() {
	pgrep -f "$work_dir/bin/Runner.Worker" >/dev/null 2>&1
}

need curl
need hostname
need pgrep
need python3

work_dir=github-runner
if [ ! -x "$work_dir/config.sh" ]; then
	note "no install found; nothing to quiesce dir=$work_dir"
	exit 0
fi
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

runner_name=$(hostname)
label=${POOL:-}
credential=$(token_value)

# A minted registration holds no API credential and set its labels when it
# registered, so there is no label to take off: the runtime's SIGINT, sent once the
# job below has finished, is what stops the listener taking another.
if is_minted "$credential"; then
	note "minted registration; no label to remove, relying on the stop signal name=$runner_name"
elif [ -z "$label" ]; then
	note "no pool label to remove; relying on the stop signal name=$runner_name"
else
	[ -n "${URL:-}" ] || fail "URL is required"
	github_token=$credential
	api_path=$(github_api_path)
	runner_id=$(find_runner_id) || fail "failed to list runners name=$runner_name"
	if [ -z "$runner_id" ]; then
		note "runner is not registered; nothing to unlabel name=$runner_name"
	else
		note "removing the pool label so no new job is routed here name=$runner_name id=$runner_id label=$label"
		curl -fsSL -X DELETE -o /dev/null \
			-H "Accept: application/vnd.github+json" \
			-H "Authorization: token $github_token" \
			"https://api.github.com/$api_path/actions/runners/$runner_id/labels/$label" ||
			note "label removal failed; continuing to wait for the current job name=$runner_name label=$label"
	fi
fi

if ! worker_running; then
	note "no job in flight; safe to stop name=$runner_name"
	exit 0
fi

note "waiting for the current job to finish name=$runner_name timeout=${JOB_TIMEOUT}s"
waited=0
while worker_running; do
	if [ "$waited" -ge "$JOB_TIMEOUT" ]; then
		fail "job was still running after ${JOB_TIMEOUT}s name=$runner_name"
	fi
	sleep "$POLL_INTERVAL"
	waited=$((waited + POLL_INTERVAL))
done

note "job finished; safe to stop name=$runner_name waited=${waited}s"
