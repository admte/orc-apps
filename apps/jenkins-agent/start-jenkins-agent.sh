#!/bin/sh
set -eu

# Start phase: the packaged script that replaced the inline `start.command`, so each
# platform resolves its own start. A start command that resolves — from config or, as
# here, from a packaged script — together with `start.service: jenkins-agent` is what
# selects runtime-managed service mode, so the node still writes the service
# definition itself and this package ships no unit file and enables nothing for boot.
#
# setpriv (never su or runuser) drops to the jenkins account inside the same session,
# so the Swarm client stays the service's own process and the stop signal reaches it.
# Every step execs: this script becomes setpriv, which becomes the runner, which
# becomes the JVM, so the service's main pid is the JVM itself.

AGENT_DIR=${AGENT_DIR:-/var/lib/jenkins-agent}
SERVICE_USER=${SERVICE_USER:-jenkins}
RUNNER_DIR=${RUNNER_DIR:-/etc/jenkins-agent}
RUNNER_PATH="$RUNNER_DIR/jenkins-agent.sh"
# Where the platform chain is staged for the runner. See stage_ca_bundle.
CA_PATH="$AGENT_DIR/platform-ca.pem"

fail() {
	echo "jenkins-agent start: $*" >&2
	exit 1
}

# Copies the platform's trust chain somewhere the jenkins account can read.
#
# CA_BUNDLE_FILE is the runtime's own materialization of the `ca_bundle` param: it
# lives in a 0700 directory owned by the account the runtime runs as, and it is
# withdrawn when the app stops. This script still runs as that account, so it stages
# a readable copy before setpriv hands the rest of the start to jenkins.
#
# Copied on every start, never at install: the platform's certificates are
# short-lived and renewed by restarting the app, and install is also the phase a pool
# bake snapshots — a chain baked into an image would be stale on first boot. When
# nothing is supplied the stale copy is removed, so a controller that moved to a
# publicly issued certificate is not left verifying against yesterday's chain.
stage_ca_bundle() {
	if [ -n "${CA_BUNDLE_FILE:-}" ] && [ -s "$CA_BUNDLE_FILE" ]; then
		cat "$CA_BUNDLE_FILE" >"$CA_PATH" || fail "failed to stage the CA bundle path=$CA_PATH"
		chmod 0644 "$CA_PATH"
		chown "$SERVICE_USER:$SERVICE_USER" "$CA_PATH" 2>/dev/null || true
		echo "jenkins-agent start: staged the platform CA bundle path=$CA_PATH" >&2
		return 0
	fi
	rm -f "$CA_PATH"
	echo "jenkins-agent start: no platform CA supplied; using the OS trust store" >&2
}

[ -x "$RUNNER_PATH" ] || fail "no install found; install must run first path=$RUNNER_PATH"
[ -n "${JENKINS_URL:-}" ] || fail "JENKINS_URL is required"
[ -n "${JENKINS_USERNAME:-}" ] || fail "JENKINS_USERNAME is required"

stage_ca_bundle

# The account has no home directory, so HOME points at the agent directory it owns.
# -disableClientsUniqueId makes the Swarm node name the host name, verbatim, which is
# the name stop-jenkins-agent.sh looks up. The CA path is passed even when nothing was
# staged: the runner treats a missing file as "no platform CA", which is the same
# thing an unresolved param means.
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env HOME="$AGENT_DIR" \
	"$RUNNER_PATH" \
	"$JENKINS_URL" "$JENKINS_USERNAME" "$AGENT_DIR/jenkins.password" \
	"$(hostname)" "${LABELS:-}" "$AGENT_DIR" \
	"$AGENT_DIR/logging.properties" "$CA_PATH"
