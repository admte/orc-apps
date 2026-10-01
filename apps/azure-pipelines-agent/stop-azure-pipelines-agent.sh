#!/bin/sh
set -eu

# Quiesce hook: the agent is still running and may be mid-job. Disable it through
# the API so the pool stops routing work here, then wait for the worker that is
# already running to finish, then exit 0. Stopping the agent host is the runtime's
# next step; deregistering is stopped-azure-pipelines-agent.sh's, and only when
# the node is going away for good.
#
# The wait belongs here rather than to the SIGINT that follows: this command gets
# the whole stop.timeout, while the signal is cut off after `grace`.

# Kept under the 1h stop.timeout so the wait ends with a message of its own rather
# than being cut off mid-poll.
JOB_TIMEOUT=${JOB_TIMEOUT:-3540}
POLL_INTERVAL=${POLL_INTERVAL:-10}
API_VERSION=${AZP_API_VERSION:-7.1}

fail() {
	echo "azure-pipelines-agent stop: $*" >&2
	exit 1
}

note() {
	echo "azure-pipelines-agent stop: $*" >&2
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

first_id() {
	python3 -c '
import json, sys
value = json.load(sys.stdin).get("value") or []
print(value[0].get("id", "") if value else "")
'
}

url_encode() {
	python3 -c 'import sys,urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

api_call() {
	method=$1
	path=$2
	shift 2
	printf 'user = ":%s"\n' "$azp_token" |
		curl -fsSL -K - -X "$method" "$@" "$org/_apis/$path"
}

# A job runs in Agent.Worker, a child the agent host spawns out of its own
# directory; no worker means no job in flight.
worker_running() {
	pgrep -f "$work_dir/bin/Agent.Worker" >/dev/null 2>&1
}

need curl
need hostname
need pgrep
need python3

work_dir=azure-pipelines-agent
if [ ! -x "$work_dir/config.sh" ]; then
	note "no install found; nothing to quiesce dir=$work_dir"
	exit 0
fi
# The physical path: the worker's command line carries the one .NET resolved its
# own binary to, so a work directory under a symlink would otherwise never match
# and a running job would read as none — and be cut off by the stop signal.
work_dir=$(CDPATH= cd -- "$work_dir" && pwd -P)

agent_name=$(hostname)
agent_pool=${AGENT_POOL:-${POOL:-}}
azp_token=$(token_value)
org=${URL:-}
org=${org%/}

if [ -z "$azp_token" ] || [ -z "$org" ] || [ -z "$agent_pool" ]; then
	note "no URL, token or pool; relying on the stop signal name=$agent_name"
else
	note "disabling the agent so no new job is routed here name=$agent_name pool=$agent_pool"
	pool_id=$(api_call GET "distributedtask/pools?poolName=$(url_encode "$agent_pool")&api-version=$API_VERSION" |
		first_id) || pool_id=''
	agent_id=''
	if [ -n "$pool_id" ]; then
		agent_id=$(api_call GET "distributedtask/pools/$pool_id/agents?agentName=$(url_encode "$agent_name")&api-version=$API_VERSION" |
			first_id) || agent_id=''
	fi
	if [ -z "$agent_id" ]; then
		note "agent is not registered; nothing to disable name=$agent_name"
	else
		api_call PATCH "distributedtask/pools/$pool_id/agents/$agent_id?api-version=$API_VERSION" \
			-o /dev/null -H 'Content-Type: application/json' \
			--data "{\"id\":$agent_id,\"enabled\":false}" ||
			note "could not disable the agent; waiting for the job anyway name=$agent_name id=$agent_id"
	fi
fi

if ! worker_running; then
	note "no job in flight; safe to stop name=$agent_name"
	exit 0
fi

note "waiting for the current job to finish name=$agent_name timeout=${JOB_TIMEOUT}s"
waited=0
while worker_running; do
	if [ "$waited" -ge "$JOB_TIMEOUT" ]; then
		fail "job was still running after ${JOB_TIMEOUT}s name=$agent_name"
	fi
	sleep "$POLL_INTERVAL"
	waited=$((waited + POLL_INTERVAL))
done

note "job finished; safe to stop name=$agent_name waited=${waited}s"
