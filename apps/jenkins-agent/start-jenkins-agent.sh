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

usage() {
	cat <<'USAGE'
Usage: start-jenkins-agent.sh --url=URL --username=NAME [--labels=LIST]
                              [--tls-ca-file=PATH] [--agent-dir=DIR]
                              [--service-user=NAME] [--runner-dir=DIR]

Runs the Jenkins Swarm client in the foreground as the agent's account, named
after this machine. Run as root, after install.

  --url=URL            Jenkins controller URL
  --username=NAME      Jenkins user the agent connects as
  --labels=LIST        space-separated labels for the agent
  --tls-ca-file=PATH   file holding extra CA certificates (PEM) to verify the
                       controller with, trusted alongside the system CAs
  --agent-dir=DIR      the agent's own directory (default: /var/lib/jenkins-agent)
  --service-user=NAME  account the agent runs as (default: jenkins)
  --runner-dir=DIR     where install copied the runner (default: /etc/jenkins-agent)
  --help               show this help
USAGE
}

fail() {
	echo "jenkins-agent start: $*" >&2
	exit 1
}

usage_error() {
	echo "jenkins-agent start: $*" >&2
	usage >&2
	exit 2
}

jenkins_url=
jenkins_username=
labels=
tls_ca_file=
agent_dir=/var/lib/jenkins-agent
service_user=jenkins
runner_dir=/etc/jenkins-agent
for arg; do
	case $arg in
	--url=*) jenkins_url=${arg#--url=} ;;
	--username=*) jenkins_username=${arg#--username=} ;;
	--labels=*) labels=${arg#--labels=} ;;
	--tls-ca-file=*) tls_ca_file=${arg#--tls-ca-file=} ;;
	--agent-dir=*) agent_dir=${arg#--agent-dir=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--runner-dir=*) runner_dir=${arg#--runner-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$jenkins_url" ] || usage_error "--url is required"
[ -n "$jenkins_username" ] || usage_error "--username is required"
[ -n "$agent_dir" ] || usage_error "--agent-dir must not be empty"
[ -n "$service_user" ] || usage_error "--service-user must not be empty"
[ -n "$runner_dir" ] || usage_error "--runner-dir must not be empty"

RUNNER_PATH="$runner_dir/jenkins-agent.sh"
# Where the supplied CA chain is staged for the runner. See stage_tls_ca.
CA_PATH="$agent_dir/platform-ca.pem"

# Copies the CA chain in --tls-ca-file somewhere the jenkins account can read.
#
# That file may be readable only by the account that runs this script, and may be
# gone once the start is over. This script still runs as that account, so it stages
# a readable copy before setpriv hands the rest of the start to jenkins.
#
# Copied on every start, never at install: a private CA's certificates may be
# short-lived and renewed by restarting the service, and a chain copied at install
# would go stale. When nothing is supplied the stale copy is removed, so a
# controller that moved to a publicly issued certificate is not left verifying
# against yesterday's chain.
stage_tls_ca() {
	if [ -n "$tls_ca_file" ] && [ -s "$tls_ca_file" ]; then
		cat "$tls_ca_file" >"$CA_PATH" || fail "failed to stage the CA bundle path=$CA_PATH"
		chmod 0644 "$CA_PATH"
		chown "$service_user:$service_user" "$CA_PATH" 2>/dev/null || true
		echo "jenkins-agent start: staged the supplied CA bundle path=$CA_PATH" >&2
		return 0
	fi
	rm -f "$CA_PATH"
	echo "jenkins-agent start: no CA bundle supplied; using the OS trust store" >&2
}

[ -x "$RUNNER_PATH" ] || fail "no install found; install must run first path=$RUNNER_PATH"

stage_tls_ca

# The account has no home directory, so HOME points at the agent directory it owns.
# -disableClientsUniqueId makes the Swarm node name the host name, verbatim, which is
# the name stop-jenkins-agent.sh looks up. The CA path is passed even when nothing was
# staged: the runner treats a missing file as "no CA bundle", the same as no
# --tls-ca-file at all.
exec setpriv --reuid="$service_user" --regid="$service_user" --init-groups \
	env HOME="$agent_dir" \
	"$RUNNER_PATH" \
	"$jenkins_url" "$jenkins_username" "$agent_dir/jenkins.password" \
	"$(hostname)" "$labels" "$agent_dir" \
	"$agent_dir/logging.properties" "$CA_PATH"
