#!/bin/sh
set -eu

# Start phase: registration is node identity, so it happens here — once per node,
# every time a node that has none comes up — and never in install. A pool bake
# runs the install phase alone and snapshots the disk, so a registration made
# there would belong to a builder that is destroyed straight afterwards, and
# `config.sh` writes `.agent` and `.credentials` — the agent's own auth material —
# into an image every clone shares. Install leaves the agent unconfigured; this
# script gives the running node its own identity, then becomes the agent host.

SERVICE_USER=${SERVICE_USER:-azagent}
API_VERSION=${AZP_API_VERSION:-7.1}

fail() {
	echo "azure-pipelines-agent start: $*" >&2
	exit 1
}

note() {
	echo "azure-pipelines-agent start: $*" >&2
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

json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

# The id of the first entry of an Azure DevOps collection response, or nothing.
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

# Azure DevOps takes the PAT as HTTP basic auth with an empty user name. It never
# reaches curl's argv: /proc/<pid>/cmdline is world readable, so a flag would show
# a token that can manage the whole agent pool to every job this node later runs.
api_call() {
	method=$1
	path=$2
	shift 2
	printf 'user = ":%s"\n' "$azp_token" |
		curl -fsSL -K - -X "$method" "$@" "$org/_apis/$path"
}

# Puts the agent back into rotation. stop-azure-pipelines-agent disables it
# through the API so the pool stops routing work here during a drain, and the
# registration itself outlives every stop reason but `terminate` — so a drained
# node would otherwise come back online disabled: healthy-looking, and silently
# never given another job. Never fatal: an agent that has to be enabled by hand
# still beats a node that will not start.
enable_agent() {
	pool_id=$(api_call GET "distributedtask/pools?poolName=$(url_encode "$agent_pool")&api-version=$API_VERSION" |
		first_id)
	[ -n "$pool_id" ] || fail "agent pool not found name=$agent_pool"
	agent_id=$(api_call GET "distributedtask/pools/$pool_id/agents?agentName=$(url_encode "$agent_name")&api-version=$API_VERSION" |
		first_id)
	[ -n "$agent_id" ] || fail "agent is not registered name=$agent_name"
	api_call PATCH "distributedtask/pools/$pool_id/agents/$agent_id?api-version=$API_VERSION" \
		-o /dev/null -H 'Content-Type: application/json' \
		--data "{\"id\":$agent_id,\"enabled\":true}" ||
		fail "could not enable the agent name=$agent_name id=$agent_id"
	note "agent enabled name=$agent_name id=$agent_id"
}

# setpriv, never su or runuser: those start a new session, which is what puts an
# app outside the process group the runtime signals.
as_service_user() {
	setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
		env HOME="$work_dir" "$@"
}

need curl
need hostname
need python3
need setpriv

work_dir=azure-pipelines-agent
[ -x "$work_dir/config.sh" ] ||
	fail "no agent install found; install must run first dir=$work_dir"
work_dir=$(CDPATH= cd -- "$work_dir" && pwd)
cd "$work_dir"

[ -n "${URL:-}" ] || fail "URL is required"
case "$URL" in
https://*) ;;
*) fail "URL must start with https://" ;;
esac
org=${URL%/}
azp_token=$(token_value)
[ -n "$azp_token" ] || fail "TOKEN_FILE or TOKEN is required"

# The agent name is the host name (a pool member is `<pool>-<slot>`). The Azure
# DevOps pool it joins is the operator's `agent_pool` when given, and otherwise
# the ORC pool's own name from the `pool.name` x-source.
agent_name=$(hostname)
agent_pool=${AGENT_POOL:-${POOL:-}}
[ -n "$agent_pool" ] || fail "agent_pool is required when the node is not in a named pool"

# `.agent` is the file config.sh writes when a directory has been configured; it
# and the `.credentials` beside it are this node's identity. Absent means the node
# has none yet — a fresh install, or the first boot of a clone whose baked image
# carried the unpacked agent but deliberately no identity — so register. Present
# means an ordinary service restart, so the same identity is reused. The stopped
# hook's `config.sh remove` deletes `.agent`, which is what makes a
# terminated-then-restarted install register again rather than start unconfigured.
if [ -f .agent ]; then
	note "already registered; reusing this node's identity name=$agent_name dir=$work_dir"
else
	note "registering name=$agent_name pool=$agent_pool"
	# Every config.sh flag can be given as VSTS_AGENT_INPUT_<NAME>, so the token
	# goes through the environment rather than the process list.
	VSTS_AGENT_INPUT_TOKEN="$azp_token" \
		as_service_user ./config.sh \
		--unattended \
		--url "$org" \
		--auth pat \
		--pool "$agent_pool" \
		--agent "$agent_name" \
		--work _work \
		--acceptTeeEula \
		--replace ||
		fail "registration failed name=$agent_name pool=$agent_pool"
fi

# Runs on both paths, and never fatally: the subshell contains a hard failure from
# anything inside, so the agent starts either way.
(enable_agent) ||
	note "could not enable the agent; starting anyway name=$agent_name"

# The agent host needs no token once it is registered, and every job it runs
# inherits its environment, so the path to the PAT stops here.
note "starting the agent name=$agent_name dir=$work_dir"
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env -u TOKEN_FILE -u TOKEN HOME="$work_dir" ./run.sh
