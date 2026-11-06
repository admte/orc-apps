#!/bin/sh
set -eu

# Runs before the service is stopped: the Swarm client is still running and still
# holds whatever build the controller gave it. Mark the node temporarily offline so
# the queue stops handing it work, wait until it reports idle, then exit 0 —
# stopping the service comes after, and is never this script's job.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=jenkins-agent-common.sh
. "$SCRIPT_DIR/jenkins-agent-common.sh"

usage() {
	cat <<USAGE
Usage: stop-jenkins-agent.sh --url=URL --username=NAME [--tls-ca-file=PATH]
                             [--stop-reason=REASON] [--agent-dir=DIR]
                             [--idle-timeout=SECONDS] [--poll-interval=SECONDS]

Marks this machine's Jenkins agent temporarily offline, so the controller hands
it no new build, and waits until it is idle. Stopping the agent itself is left
to the caller.

  --url=URL                Jenkins controller URL
  --username=NAME          Jenkins user the agent connects as
  --tls-ca-file=PATH       file holding extra CA certificates (PEM) to verify the
                           controller with; without it, the copy start staged
  --stop-reason=REASON     why the agent is stopping, shown as its offline
                           message (default: stop)
  --agent-dir=DIR          the agent's own directory
                           (default: $JENKINS_AGENT_DIR_DEFAULT)
  --idle-timeout=SECONDS   how long to wait for the build (default: 1740)
  --poll-interval=SECONDS  how often to ask whether it is idle (default: 10)
  --help                   show this help
USAGE
}

fail() {
	echo "jenkins-agent stop: $*" >&2
	exit 1
}

usage_error() {
	echo "jenkins-agent stop: $*" >&2
	usage >&2
	exit 2
}

jenkins_url=
jenkins_username=
tls_ca_file=
stop_reason=
agent_dir=$JENKINS_AGENT_DIR_DEFAULT
# Just under half an hour, so a stop that is given half an hour ends with a message
# of its own rather than being cut off mid-poll.
idle_timeout=1740
poll_interval=10
for arg; do
	case $arg in
	--url=*) jenkins_url=${arg#--url=} ;;
	--username=*) jenkins_username=${arg#--username=} ;;
	--tls-ca-file=*) tls_ca_file=${arg#--tls-ca-file=} ;;
	--stop-reason=*) stop_reason=${arg#--stop-reason=} ;;
	--agent-dir=*) agent_dir=${arg#--agent-dir=} ;;
	--idle-timeout=*) idle_timeout=${arg#--idle-timeout=} ;;
	--poll-interval=*) poll_interval=${arg#--poll-interval=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$jenkins_url" ] || usage_error "--url is required"
[ -n "$jenkins_username" ] || usage_error "--username is required"
[ -n "$agent_dir" ] || usage_error "--agent-dir must not be empty"
case $idle_timeout in
'' | *[!0-9]*) usage_error "--idle-timeout must be a number of seconds" ;;
esac
case $poll_interval in
'' | *[!0-9]*) usage_error "--poll-interval must be a number of seconds" ;;
esac

PASSWORD_FILE="$agent_dir/jenkins.password"
# The copy start-jenkins-agent.sh staged for the running agent; the fallback when
# no --tls-ca-file is given to this stop.
STAGED_CA_PATH="$agent_dir/platform-ca.pem"

note() {
	echo "jenkins-agent stop: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need hostname
need python3

if [ ! -r "$PASSWORD_FILE" ]; then
	note "no install found; nothing to quiesce dir=$agent_dir"
	exit 0
fi
jenkins_password=$(tr -d '\r\n' <"$PASSWORD_FILE")
[ -n "$jenkins_password" ] || fail "password file is empty: $PASSWORD_FILE"

# -disableClientsUniqueId makes the Swarm node name the host name, verbatim.
node=$(hostname)
[ -n "$node" ] || fail "hostname is empty"

# The controller this script talks to is the one the running agent is connected to,
# so it verifies against the same chain: --tls-ca-file when it is given, else the
# copy start staged, which is what answers when a CA bundle was given to start but
# not to this stop. Neither present means the OS trust store, unchanged.
trust_source=""
if [ -n "$tls_ca_file" ] && [ -s "$tls_ca_file" ]; then
	trust_source=$tls_ca_file
elif [ -s "$STAGED_CA_PATH" ]; then
	trust_source=$STAGED_CA_PATH
fi
if [ -n "$trust_source" ]; then
	trust_dir=$(mktemp -d)
	trap 'rm -rf "$trust_dir"' EXIT INT TERM
	jenkins_trust_init "$trust_source" "$trust_dir/ca-trust.pem"
	note "verifying the controller against the supplied CA source=$trust_source"
fi

jenkins_session_open "$jenkins_url" "$jenkins_username" "$jenkins_password"
computer="/computer/$node"
body="$jenkins_session_dir/body"
offline_message=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' \
	"jenkins-agent ${stop_reason:-stop}")

mark_offline() {
	jenkins_fetch_crumb optional
	jenkins_post "$computer/toggleOffline?offlineMessage=$offline_message" -o /dev/null 2>/dev/null && return 0
	# Almost always a missing or stale crumb; take a fresh one and insist.
	jenkins_fetch_crumb required
	jenkins_post "$computer/toggleOffline?offlineMessage=$offline_message" -o /dev/null
}

status=$(jenkins_fetch "$computer/api/json?tree=temporarilyOffline,idle" "$body")
case "$status" in
200) ;;
404)
	note "agent is not registered on the controller node=$node"
	jenkins_session_close
	exit 0
	;;
*)
	jenkins_session_close
	fail "controller did not answer node=$node http_status=$status"
	;;
esac

if [ "$(jenkins_json_bool temporarilyOffline <"$body")" = true ]; then
	note "agent is already offline node=$node"
else
	note "marking the agent offline so no new build is scheduled node=$node"
	# toggleOffline is a toggle, so it runs only from the online state read above.
	# Nothing clears the mark on the way back: a stop that is really a restart
	# relies on -deleteExistingClients, which drops the stale node when the client
	# reconnects, so the fresh node starts online. Keep that flag in the runner.
	mark_offline || {
		jenkins_session_close
		fail "failed to mark the agent offline node=$node"
	}
fi

note "waiting for the current build to finish node=$node timeout=${idle_timeout}s"
waited=0
while :; do
	status=$(jenkins_fetch "$computer/api/json?tree=idle" "$body")
	case "$status" in
	200)
		if [ "$(jenkins_json_bool idle <"$body")" = true ]; then
			note "agent is idle; safe to stop node=$node waited=${waited}s"
			jenkins_session_close
			exit 0
		fi
		;;
	404)
		note "agent left the controller; safe to stop node=$node waited=${waited}s"
		jenkins_session_close
		exit 0
		;;
	*)
		note "controller did not answer; retrying node=$node http_status=$status waited=${waited}s"
		;;
	esac
	[ "$waited" -lt "$idle_timeout" ] || break
	sleep "$poll_interval"
	waited=$((waited + poll_interval))
done

jenkins_session_close
fail "agent was still busy after ${idle_timeout}s node=$node"
