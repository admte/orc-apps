#!/bin/sh
set -eu

# Quiesce hook: the Swarm client is still running and still holds whatever build
# the controller gave it. Mark the node temporarily offline so the queue stops
# handing it work, wait until it reports idle, then exit 0 — stopping the service
# is the runtime's next step, never this script's.

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AGENT_DIR=${AGENT_DIR:-/var/lib/jenkins-agent}
PASSWORD_FILE="$AGENT_DIR/jenkins.password"
# Kept under the 30m stop.timeout so the wait ends with a message of its own
# rather than being cut off mid-poll.
IDLE_TIMEOUT=${IDLE_TIMEOUT:-1740}
POLL_INTERVAL=${POLL_INTERVAL:-10}

# shellcheck source=jenkins-agent-common.sh
. "$SCRIPT_DIR/jenkins-agent-common.sh"

fail() {
	echo "jenkins-agent stop: $*" >&2
	exit 1
}

note() {
	echo "jenkins-agent stop: $*" >&2
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

need curl
need hostname
need python3

[ -n "${JENKINS_URL:-}" ] || fail "JENKINS_URL is required"
[ -n "${JENKINS_USERNAME:-}" ] || fail "JENKINS_USERNAME is required"

if [ ! -r "$PASSWORD_FILE" ]; then
	note "no install found; nothing to quiesce dir=$AGENT_DIR"
	exit 0
fi
jenkins_password=$(tr -d '\r\n' <"$PASSWORD_FILE")
[ -n "$jenkins_password" ] || fail "password file is empty: $PASSWORD_FILE"

# -disableClientsUniqueId makes the Swarm node name the host name, verbatim.
node=$(hostname)
[ -n "$node" ] || fail "hostname is empty"

jenkins_session_open "$JENKINS_URL" "$JENKINS_USERNAME" "$jenkins_password"
computer="/computer/$node"
body="$jenkins_session_dir/body"
offline_message=$(python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' \
	"ORC8R node ${APP_STOP_REASON:-stop}")

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

note "waiting for the current build to finish node=$node timeout=${IDLE_TIMEOUT}s"
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
	[ "$waited" -lt "$IDLE_TIMEOUT" ] || break
	sleep "$POLL_INTERVAL"
	waited=$((waited + POLL_INTERVAL))
done

jenkins_session_close
fail "agent was still busy after ${IDLE_TIMEOUT}s node=$node"
