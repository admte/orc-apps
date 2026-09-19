#!/bin/sh
set -eu

# Quiesce hook: the runner is still running and may be mid-job. Pause it through
# the API so the queue stops routing work here, then wait for the job already
# running to finish, then exit 0. Stopping the runner is the runtime's next step;
# deleting it is stopped-gitlab-runner.sh's, and only when the node is going away
# for good.
#
# The wait belongs here rather than to the SIGQUIT that follows: the signal starts
# gitlab-runner's own graceful shutdown, but the runtime only allows `grace` for
# it (30s) before killing what survives, while this command has the whole
# `stop.timeout` (1h). github-runner waits in its stop hook for the same reason.

# Kept under the 1h stop.timeout so the wait ends with a message of its own
# rather than being cut off mid-poll.
JOB_TIMEOUT=${JOB_TIMEOUT:-3540}
POLL_INTERVAL=${POLL_INTERVAL:-10}

fail() {
	echo "gitlab-runner stop: $*" >&2
	exit 1
}

note() {
	echo "gitlab-runner stop: $*" >&2
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
		echo ''
	fi
}

# The access token never reaches curl's argv: this hook runs while a job may be
# executing on the node, and /proc/<pid>/cmdline is world readable.
api_call() {
	method=$1
	path=$2
	shift 2
	printf 'header = "PRIVATE-TOKEN: %s"\n' "$gitlab_token" |
		curl -fsSL -K - -X "$method" "$@" "$api/$path"
}

# start-gitlab-runner.sh execs the runner, so APP_PID is gitlab-runner itself. A
# job runs in processes it spawns; no children means no job in flight.
job_running() {
	pgrep -P "$APP_PID" >/dev/null 2>&1
}

need curl
need pgrep

id_file=gitlab-runner/runner.id
if [ ! -s "$id_file" ]; then
	note "no runner recorded; nothing to pause"
else
	runner_id=$(cat "$id_file")
	gitlab_token=$(token_value)
	if [ -z "$gitlab_token" ]; then
		note "no access token; cannot pause the runner id=$runner_id"
	elif [ -z "${URL:-}" ]; then
		note "no URL; cannot pause the runner id=$runner_id"
	else
		rest=${URL#https://}
		api="https://${rest%%/*}/api/v4"
		note "pausing the runner so no new job is routed here id=$runner_id"
		api_call PUT "runners/$runner_id" -o /dev/null --data-urlencode "paused=true" ||
			note "pause failed; waiting for the job anyway id=$runner_id"
	fi
fi

if [ -z "${APP_PID:-}" ]; then
	note "no runner process to wait for"
	exit 0
fi

if ! job_running; then
	note "no job in flight; safe to stop pid=$APP_PID"
	exit 0
fi

note "waiting for the current job to finish pid=$APP_PID timeout=${JOB_TIMEOUT}s"
waited=0
while job_running; do
	if [ "$waited" -ge "$JOB_TIMEOUT" ]; then
		fail "job was still running after ${JOB_TIMEOUT}s pid=$APP_PID"
	fi
	sleep "$POLL_INTERVAL"
	waited=$((waited + POLL_INTERVAL))
done

note "job finished; safe to stop waited=${waited}s"
