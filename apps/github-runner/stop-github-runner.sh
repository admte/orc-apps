#!/bin/sh
set -eu

# Quiesce hook: the listener is still running and may be mid-job. With a personal
# access token, take the pool label off the runner so the queue stops routing work
# here; in either mode, wait for the worker that is already running to finish,
# then exit 0. Stopping the listener is the runtime's next step; deregistering is
# stopped-github-runner.sh's, and only when the node is going away for good.

usage() {
	cat <<'USAGE'
Usage: stop-github-runner.sh [--url=URL] [--token-file=PATH] [--pool=LABEL]
                             [--job-timeout=SECONDS] [--poll-interval=SECONDS]

Drains this node's runner: with a personal access token, takes the pool label
off so no new job is routed here, then waits for the job in flight to finish.
Leaves the listener running and the registration in place.

  --url=URL                repository or organization URL (personal access token)
  --token-file=PATH        file holding a personal access token or orc8r's
                           minted registration (JSON)
  --pool=LABEL             label to take off (personal access token)
  --job-timeout=SECONDS    longest wait for the job in flight (default: 3540)
  --poll-interval=SECONDS  how often to look for it (default: 10)
  --help                   show this help
USAGE
}

fail() {
	echo "github-runner stop: $*" >&2
	exit 1
}

usage_error() {
	echo "github-runner stop: $*" >&2
	usage >&2
	exit 2
}

repo_url=
token_file=
pool=
# Kept under the 1h stop.timeout so the wait ends with a message of its own
# rather than being cut off mid-poll.
job_timeout=3540
poll_interval=10
for arg; do
	case $arg in
	--url=*) repo_url=${arg#--url=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--pool=*) pool=${arg#--pool=} ;;
	--job-timeout=*) job_timeout=${arg#--job-timeout=} ;;
	--poll-interval=*) poll_interval=${arg#--poll-interval=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
case $job_timeout in
'' | *[!0-9]*) usage_error "--job-timeout must be a whole number of seconds" ;;
esac
case $poll_interval in
'' | *[!0-9]* | 0) usage_error "--poll-interval must be a positive whole number of seconds" ;;
esac

note() {
	echo "github-runner stop: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

token_value() {
	[ -n "$token_file" ] || fail "--token-file is required"
	tr -d '\r\n' <"$token_file"
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
label=$pool
# Absent is not fatal: without a credential there is no label to take off, and
# the wait for the current job below still holds.
credential=$(token_value 2>/dev/null) || credential=

# A minted registration holds no API credential and set its labels when it
# registered, so there is no label to take off: the runtime's SIGINT, sent once the
# job below has finished, is what stops the listener taking another.
if [ -z "$credential" ]; then
	note "no credential available; skipping the label step name=$runner_name"
elif is_minted "$credential"; then
	note "minted registration; no label to remove, relying on the stop signal name=$runner_name"
elif [ -z "$label" ]; then
	note "no pool label to remove; relying on the stop signal name=$runner_name"
else
	[ -n "$repo_url" ] || fail "--url is required"
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

note "waiting for the current job to finish name=$runner_name timeout=${job_timeout}s"
waited=0
while worker_running; do
	if [ "$waited" -ge "$job_timeout" ]; then
		fail "job was still running after ${job_timeout}s name=$runner_name"
	fi
	sleep "$poll_interval"
	waited=$((waited + poll_interval))
done

note "job finished; safe to stop name=$runner_name waited=${waited}s"
