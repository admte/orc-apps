#!/bin/sh
set -eu

# Runs before the listener is stopped, while it may still be mid-job. With a
# personal access token, take --labels off the runner so the queue stops routing
# work here; in either mode, wait for the worker that is already running to finish,
# then exit 0. The listener is left running, to be stopped once this exits;
# deregistering is stopped-github-runner.sh's, and only when the runner is going
# away for good.

usage() {
	cat <<'USAGE'
Usage: stop-github-runner.sh [--url=URL] [--token-file=PATH] [--labels=LIST]
                             [--job-timeout=SECONDS] [--poll-interval=SECONDS]

Drains this machine's runner: with a personal access token, takes the labels
off so no new job is routed here, then waits for the job in flight to finish.
Leaves the listener running and the registration in place.

  --url=URL                repository or organization URL (personal access token)
  --token-file=PATH        file holding a personal access token or a runner
                           registration as a JSON object
  --labels=LIST            comma-separated labels to take off (personal access
                           token)
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

# Sets labels to the comma-separated list in $1 with the space around each item
# trimmed and empty items dropped. GitHub refuses a label with a space in it or
# longer than 256 characters, so such a label stops here.
parse_labels() {
	labels=
	rest=$1,
	while [ -n "$rest" ]; do
		item=${rest%%,*}
		rest=${rest#*,}
		item=${item#"${item%%[![:space:]]*}"}
		item=${item%"${item##*[![:space:]]}"}
		[ -n "$item" ] || continue
		case $item in
		*[[:space:][:cntrl:]]*) usage_error "label '$item' contains a space or a control character" ;;
		esac
		[ "${#item}" -le 256 ] || usage_error "label '$item' is longer than 256 characters"
		labels=${labels:+$labels,}$item
	done
}

repo_url=
token_file=
labels_arg=
# Just under an hour, so a stop that is given an hour ends with a message of its
# own rather than being cut off mid-poll.
job_timeout=3540
poll_interval=10
for arg; do
	case $arg in
	--url=*) repo_url=${arg#--url=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--labels=*) labels_arg=${arg#--labels=} ;;
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
parse_labels "$labels_arg"

# Progress to stdout; warnings and errors to stderr.
note() {
	echo "github-runner stop: $*"
}

warn() {
	echo "github-runner stop: warning: $*" >&2
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

# Prints the id and the name this directory's runner registered under, one per
# line, from `.runner`: the record config.sh writes when it registers, with a
# UTF-8 BOM. Prints nothing when the record is missing or unreadable, so the
# runner is found by its own registration, never by a name guessed here.
registration_record() {
	python3 -c '
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8-sig") as f:
        record = json.load(f)
    runner_id = record.get("agentId")
    name = record.get("agentName") or ""
except Exception:
    sys.exit(0)
if isinstance(runner_id, int) and not isinstance(runner_id, bool) and runner_id > 0:
    print(runner_id)
    print(name)
' "$1" 2>/dev/null || true
}

# A label goes into the request path, so it is percent-encoded there: a slash, a
# question mark or a hash in it would otherwise change the URL.
url_path_segment() {
	python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Takes each label in $labels off the runner, one request per label. A failure is
# logged and the rest still go: the wait for the current job below matters more.
remove_labels() {
	rest=$labels,
	while [ -n "$rest" ]; do
		label=${rest%%,*}
		rest=${rest#*,}
		curl -fsSL -X DELETE -o /dev/null \
			-H "Accept: application/vnd.github+json" \
			-H "Authorization: token $github_token" \
			"https://api.github.com/$api_path/actions/runners/$runner_id/labels/$(url_path_segment "$label")" ||
			warn "label removal failed; continuing to wait for the current job name=$runner_name label=$label"
	done
}

# A job runs in Runner.Worker, a child the listener spawns out of its own
# directory; no worker means no job in flight.
worker_running() {
	pgrep -f "$work_dir/bin/Runner.Worker" >/dev/null 2>&1
}

need curl
need pgrep
need python3

work_dir=github-runner
if [ ! -x "$work_dir/config.sh" ]; then
	note "no install found; nothing to quiesce dir=$work_dir"
	exit 0
fi
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)

record=$(registration_record "$work_dir/.runner")
runner_id=$(printf '%s\n' "$record" | sed -n 1p)
runner_name=$(printf '%s\n' "$record" | sed -n 2p)
# Names the runner in the lines below, or nothing when there is no record.
who=
if [ -n "$runner_id" ]; then
	who=" name=$runner_name"
	note "found the runner in its registration record name=$runner_name id=$runner_id file=$work_dir/.runner"
fi
# Absent is not fatal: without a credential there are no labels to take off, and
# the wait for the current job below still holds.
credential=$(token_value 2>/dev/null) || credential=

# A JSON registration, a just-in-time one included, holds no API credential and
# set its labels when it registered, so there are no labels to take off: stopping
# the listener once the job below has finished is what keeps it from taking
# another. A directory with no readable `.runner` was never registered, or no
# longer is, so there is no runner whose labels could be taken off.
if [ -z "$credential" ]; then
	note "no credential available; skipping the label step$who"
elif is_minted "$credential"; then
	note "JSON registration; no labels to remove, relying on the stop signal$who"
elif [ -z "$labels" ]; then
	note "no labels to remove; relying on the stop signal$who"
elif [ -z "$runner_id" ]; then
	note "no registration record; no runner to unlabel file=$work_dir/.runner"
else
	[ -n "$repo_url" ] || fail "--url is required"
	github_token=$credential
	api_path=$(github_api_path)
	note "removing the labels so no new job is routed here name=$runner_name id=$runner_id labels=$labels"
	remove_labels
fi

if ! worker_running; then
	note "no job in flight; safe to stop$who"
	exit 0
fi

note "waiting for the current job to finish$who timeout=${job_timeout}s"
waited=0
while worker_running; do
	if [ "$waited" -ge "$job_timeout" ]; then
		fail "job was still running after ${job_timeout}s$who"
	fi
	sleep "$poll_interval"
	waited=$((waited + poll_interval))
done

note "job finished; safe to stop$who waited=${waited}s"
