#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
AGENT_DIR=${AGENT_DIR:-/var/lib/jenkins-agent}
SERVICE_NAME=${SERVICE_NAME:-jenkins-agent}
SERVICE_USER=${SERVICE_USER:-jenkins}
SERVICE_UNIT_PATH=${SERVICE_UNIT_PATH:-/etc/systemd/system/jenkins-agent.service}
RUNNER_DIR=${RUNNER_DIR:-/etc/jenkins-agent}
RUNNER_PATH="$RUNNER_DIR/jenkins-agent.sh"
RUNNER_SOURCE="$SCRIPT_DIR/run-jenkins-agent.sh"
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

systemd_exec_arg() {
	python3 -c 'import sys; v=sys.argv[1]; print("\"%s\"" % v.replace("\\", "\\\\").replace("\"", "\\\"").replace("%", "%%").replace("$", "$$"))' "$1"
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

write_password_file() {
	printf '%s' "$jenkins_password" >"$PASSWORD_FILE"
	chmod 0600 "$PASSWORD_FILE"
}

install_runner() {
	[ -f "$RUNNER_SOURCE" ] || fail "runner script not found: $RUNNER_SOURCE"
	mkdir -p "$RUNNER_DIR"
	cp "$RUNNER_SOURCE" "$RUNNER_PATH"
	chmod 0755 "$RUNNER_PATH"
}

write_systemd_unit_file() {
	labels=${LABELS:-}
	mkdir -p "$(dirname "$SERVICE_UNIT_PATH")"
	exec_start=$(printf 'ExecStart=%s' "$(systemd_exec_arg "$RUNNER_PATH")")
	for arg in \
		"$JENKINS_URL" \
		"$JENKINS_USERNAME" \
		"$PASSWORD_FILE" \
		"$agent_name" \
		"$labels" \
		"$AGENT_DIR" \
		"$LOG_CONFIG_PATH"
	do
		exec_start="$exec_start $(systemd_exec_arg "$arg")"
	done

	{
		printf '%s\n' '[Unit]'
		printf '%s\n' 'Description=Jenkins agent'
		printf '%s\n' 'After=network-online.target'
		printf '%s\n' 'Wants=network-online.target'
		printf '%s\n' ''
		printf '%s\n' '[Service]'
		printf '%s\n' 'Type=simple'
		printf 'User=%s\n' "$SERVICE_USER"
		printf 'WorkingDirectory=%s\n' "$AGENT_DIR"
		printf '%s\n' "$exec_start"
		printf '%s\n' 'Restart=always'
		printf '%s\n' 'RestartSec=5'
		printf '%s\n' ''
		printf '%s\n' '[Install]'
		printf '%s\n' 'WantedBy=multi-user.target'
	} >"$SERVICE_UNIT_PATH"
	chmod 0644 "$SERVICE_UNIT_PATH"
}

need hostname
need python3
need systemctl
need useradd
[ "$(id -u)" -eq 0 ] || fail "must run as root"
[ -n "${JENKINS_URL:-}" ] || fail "JENKINS_URL is required"
[ -n "${JENKINS_USERNAME:-}" ] || fail "JENKINS_USERNAME is required"

jenkins_password=$(password_value)
agent_name=$(hostname)
[ -n "$agent_name" ] || fail "hostname is empty"

echo "Ensuring Jenkins agent directory ($AGENT_DIR)" >&2
mkdir -p "$AGENT_DIR"
ensure_service_user

echo "Writing logging config" >&2
write_logging_config

echo "Writing password file" >&2
write_password_file

echo "Installing Jenkins agent runner ($RUNNER_PATH)" >&2
install_runner

echo "Writing systemd unit ($SERVICE_UNIT_PATH)" >&2
write_systemd_unit_file

chown -R "$SERVICE_USER:$SERVICE_USER" "$AGENT_DIR"
systemctl daemon-reload

echo "Jenkins agent install complete" >&2
