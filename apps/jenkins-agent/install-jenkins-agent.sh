#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=jenkins-agent-common.sh
. "$SCRIPT_DIR/jenkins-agent-common.sh"

usage() {
	cat <<USAGE
Usage: install-jenkins-agent.sh --password-file=PATH [--agent-dir=DIR]
                                [--service-user=NAME] [--runner-dir=DIR]

Lays out the Jenkins agent's directory, its logging config and a copy of the
password it reads on every start, creates the account it runs as, and copies
the runner to a fixed path. Run as root.

  --password-file=PATH file holding the Jenkins user's API token or password
  --agent-dir=DIR      the agent's own directory
                       (default: $JENKINS_AGENT_DIR_DEFAULT)
  --service-user=NAME  account the agent runs as (default: $JENKINS_SERVICE_USER_DEFAULT)
  --runner-dir=DIR     where the runner is copied
                       (default: $JENKINS_RUNNER_DIR_DEFAULT)
  --help               show this help
USAGE
}

fail() {
	echo "jenkins-agent install: $*" >&2
	exit 1
}

usage_error() {
	echo "jenkins-agent install: $*" >&2
	usage >&2
	exit 2
}

password_file=
agent_dir=$JENKINS_AGENT_DIR_DEFAULT
service_user=$JENKINS_SERVICE_USER_DEFAULT
runner_dir=$JENKINS_RUNNER_DIR_DEFAULT
for arg; do
	case $arg in
	--password-file=*) password_file=${arg#--password-file=} ;;
	--agent-dir=*) agent_dir=${arg#--agent-dir=} ;;
	--service-user=*) service_user=${arg#--service-user=} ;;
	--runner-dir=*) runner_dir=${arg#--runner-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$password_file" ] || usage_error "--password-file is required"
[ -n "$agent_dir" ] || usage_error "--agent-dir must not be empty"
[ -n "$service_user" ] || usage_error "--service-user must not be empty"
[ -n "$runner_dir" ] || usage_error "--runner-dir must not be empty"

RUNNER_PATH="$runner_dir/jenkins-agent.sh"
COMMON_PATH="$runner_dir/jenkins-agent-common.sh"
LOG_CONFIG_PATH="$agent_dir/logging.properties"
PASSWORD_FILE="$agent_dir/jenkins.password"

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

password_value() {
	[ -r "$password_file" ] || fail "password file is not readable: $password_file"
	tr -d '\r\n' <"$password_file"
}

ensure_service_user() {
	if id "$service_user" >/dev/null 2>&1; then
		return 0
	fi
	useradd -r -U -M "$service_user"
	id "$service_user" >/dev/null 2>&1 || fail "failed to create service user $service_user"
}

write_logging_config() {
	cat >"$LOG_CONFIG_PATH" <<'EOF'
.level = INFO
handlers= java.util.logging.ConsoleHandler

java.util.logging.ConsoleHandler.level=INFO
java.util.logging.ConsoleHandler.formatter=java.util.logging.SimpleFormatter
java.util.logging.SimpleFormatter.format = %4$s %2$s %5$s%6$s%n
EOF
	chmod 0644 "$LOG_CONFIG_PATH"
}

# The password is copied into the agent directory: the --password-file given here
# may be gone by the next start, while the Swarm client re-reads its password on
# every service restart. Created under umask 077, so it is never readable by others,
# not even for the moment before the chmod; the chmod covers a file an earlier
# install left with wider permissions.
write_password_file() {
	(
		umask 077
		printf '%s' "$jenkins_password" >"$PASSWORD_FILE"
	)
	chmod 0600 "$PASSWORD_FILE"
}

# The runner and its helper live at a fixed path so a service that runs
# start-jenkins-agent.sh keeps working regardless of where these scripts were
# unpacked; start-jenkins-agent.sh invokes this copy, not the one beside it.
install_runner() {
	[ -f "$SCRIPT_DIR/run-jenkins-agent.sh" ] || fail "runner script not found in $SCRIPT_DIR"
	[ -f "$SCRIPT_DIR/jenkins-agent-common.sh" ] || fail "helper script not found in $SCRIPT_DIR"
	mkdir -p "$runner_dir"
	cp "$SCRIPT_DIR/run-jenkins-agent.sh" "$RUNNER_PATH"
	cp "$SCRIPT_DIR/jenkins-agent-common.sh" "$COMMON_PATH"
	chmod 0755 "$RUNNER_PATH"
	chmod 0644 "$COMMON_PATH"
}

need curl
need python3
need setpriv
need useradd
[ "$(id -u)" -eq 0 ] || fail "must run as root"

jenkins_password=$(password_value)

echo "jenkins-agent install: preparing the agent directory dir=$agent_dir" >&2
mkdir -p "$agent_dir"
ensure_service_user

echo "jenkins-agent install: writing the logging config path=$LOG_CONFIG_PATH" >&2
write_logging_config

echo "jenkins-agent install: writing the password file path=$PASSWORD_FILE" >&2
write_password_file

echo "jenkins-agent install: installing the runner path=$RUNNER_PATH" >&2
install_runner

chown -R "$service_user:$service_user" "$agent_dir"

echo "jenkins-agent install: complete user=$service_user dir=$agent_dir" >&2
