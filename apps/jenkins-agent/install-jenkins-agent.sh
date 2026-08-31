#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AGENT_DIR=${AGENT_DIR:-/var/lib/jenkins-agent}
SERVICE_USER=${SERVICE_USER:-jenkins}
RUNNER_DIR=${RUNNER_DIR:-/etc/jenkins-agent}
RUNNER_PATH="$RUNNER_DIR/jenkins-agent.sh"
COMMON_PATH="$RUNNER_DIR/jenkins-agent-common.sh"
LOG_CONFIG_PATH="$AGENT_DIR/logging.properties"
PASSWORD_FILE="$AGENT_DIR/jenkins.password"

fail() {
	echo "jenkins-agent install: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

password_value() {
	if [ -n "${JENKINS_PASSWORD_FILE:-}" ]; then
		tr -d '\r\n' <"$JENKINS_PASSWORD_FILE"
	elif [ -n "${JENKINS_PASSWORD:-}" ]; then
		printf '%s' "$JENKINS_PASSWORD"
	else
		fail "JENKINS_PASSWORD_FILE or JENKINS_PASSWORD is required"
	fi
}

ensure_service_user() {
	if id "$SERVICE_USER" >/dev/null 2>&1; then
		return 0
	fi
	useradd -r -U -M "$SERVICE_USER"
	id "$SERVICE_USER" >/dev/null 2>&1 || fail "failed to create service user $SERVICE_USER"
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

# The password outlives the install phase: the sensitive param file is withdrawn
# once the app has started, while the Swarm client re-reads its password on every
# service restart.
write_password_file() {
	printf '%s' "$jenkins_password" >"$PASSWORD_FILE"
	chmod 0600 "$PASSWORD_FILE"
}

# The runner and its helper live at a fixed path so the service definition the
# node writes from `start:` keeps working regardless of where the app's working
# directory lands; start-jenkins-agent.sh invokes this copy, not the packaged one.
install_runner() {
	[ -f "$SCRIPT_DIR/run-jenkins-agent.sh" ] || fail "runner script not found in $SCRIPT_DIR"
	[ -f "$SCRIPT_DIR/jenkins-agent-common.sh" ] || fail "helper script not found in $SCRIPT_DIR"
	mkdir -p "$RUNNER_DIR"
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
[ -n "${JENKINS_URL:-}" ] || fail "JENKINS_URL is required"
[ -n "${JENKINS_USERNAME:-}" ] || fail "JENKINS_USERNAME is required"

jenkins_password=$(password_value)

echo "jenkins-agent install: preparing the agent directory dir=$AGENT_DIR" >&2
mkdir -p "$AGENT_DIR"
ensure_service_user

echo "jenkins-agent install: writing the logging config path=$LOG_CONFIG_PATH" >&2
write_logging_config

echo "jenkins-agent install: writing the password file path=$PASSWORD_FILE" >&2
write_password_file

echo "jenkins-agent install: installing the runner path=$RUNNER_PATH" >&2
install_runner

chown -R "$SERVICE_USER:$SERVICE_USER" "$AGENT_DIR"

echo "jenkins-agent install: complete user=$SERVICE_USER dir=$AGENT_DIR" >&2
