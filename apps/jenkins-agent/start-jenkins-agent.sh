#!/bin/sh
set -eu

# Runs the Swarm client in the foreground, for a service manager to supervise: this
# script is meant to be a service's main process. The package ships no unit file and
# enables nothing for boot.
#
# setpriv (never su or runuser) drops to the jenkins account inside the same session,
# so the Swarm client stays the service's own process and the stop signal reaches it.
# Every step execs: this script becomes setpriv, which becomes the runner, which
# becomes the JVM, so the service's main pid is the JVM itself.

AGENT_DIR=${AGENT_DIR:-/var/lib/jenkins-agent}
SERVICE_USER=${SERVICE_USER:-jenkins}
RUNNER_DIR=${RUNNER_DIR:-/etc/jenkins-agent}
RUNNER_PATH="$RUNNER_DIR/jenkins-agent.sh"
# Where the supplied CA chain is staged for the runner. See stage_tls_ca.
CA_PATH="$AGENT_DIR/platform-ca.pem"

fail() {
	echo "jenkins-agent start: $*" >&2
	exit 1
}

# Copies the CA chain in TLS_CA_FILE somewhere the jenkins account can read.
#
# TLS_CA_FILE may be readable only by the account that runs this script, and may be
# gone once the start is over. This script still runs as that account, so it stages
# a readable copy before setpriv hands the rest of the start to jenkins.
#
# Copied on every start, never at install: a private CA's certificates may be
# short-lived and renewed by restarting the service, and a chain copied at install
# would go stale. When nothing is supplied the stale copy is removed, so a
# controller that moved to a publicly issued certificate is not left verifying
# against yesterday's chain.
stage_tls_ca() {
	if [ -n "${TLS_CA_FILE:-}" ] && [ -s "$TLS_CA_FILE" ]; then
		cat "$TLS_CA_FILE" >"$CA_PATH" || fail "failed to stage the CA bundle path=$CA_PATH"
		chmod 0644 "$CA_PATH"
		chown "$SERVICE_USER:$SERVICE_USER" "$CA_PATH" 2>/dev/null || true
		echo "jenkins-agent start: staged the supplied CA bundle path=$CA_PATH" >&2
		return 0
	fi
	rm -f "$CA_PATH"
	echo "jenkins-agent start: no CA bundle supplied; using the OS trust store" >&2
}

[ -x "$RUNNER_PATH" ] || fail "no install found; install must run first path=$RUNNER_PATH"
[ -n "${JENKINS_URL:-}" ] || fail "JENKINS_URL is required"
[ -n "${JENKINS_USERNAME:-}" ] || fail "JENKINS_USERNAME is required"

stage_tls_ca

# The account has no home directory, so HOME points at the agent directory it owns.
# -disableClientsUniqueId makes the Swarm node name the host name, verbatim, which is
# the name stop-jenkins-agent.sh looks up. The CA path is passed even when nothing was
# staged: the runner treats a missing file as "no CA bundle", the same as no
# TLS_CA_FILE at all.
exec setpriv --reuid="$SERVICE_USER" --regid="$SERVICE_USER" --init-groups \
	env HOME="$AGENT_DIR" \
	"$RUNNER_PATH" \
	"$JENKINS_URL" "$JENKINS_USERNAME" "$AGENT_DIR/jenkins.password" \
	"$(hostname)" "${LABELS:-}" "$AGENT_DIR" \
	"$AGENT_DIR/logging.properties" "$CA_PATH"
