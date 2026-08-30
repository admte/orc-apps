#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
# shellcheck source=jenkins-agent-common.sh
. "$SCRIPT_DIR/jenkins-agent-common.sh"

fail() {
	echo "jenkins-agent runner: $*" >&2
	exit 1
}

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

[ "$#" -eq 7 ] || fail "expected Jenkins URL, username, password file, agent name, labels, agent directory, and logging config"

JENKINS_URL=$1
JENKINS_USERNAME=$2
PASSWORD_FILE=$3
AGENT_NAME=$4
LABELS=$5
AGENT_DIR=$6
LOG_CONFIG_PATH=$7
SWARM_JAR_PATH="$AGENT_DIR/swarm-client.jar"

[ -n "$AGENT_NAME" ] || AGENT_NAME=$(hostname)
[ -n "$AGENT_NAME" ] || fail "agent name is empty"

machine_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) printf 'x64' ;;
	aarch64 | arm64) printf 'aarch64' ;;
	*) fail "unsupported architecture $(uname -m)" ;;
	esac
}

fetch_jenkins_controller_info() {
	jenkins_session_open "$JENKINS_URL" "$JENKINS_USERNAME" "$jenkins_password"
	body_file="$jenkins_session_dir/script"

	script='import groovy.json.JsonOutput;

swarmPlugin = Jenkins.instance.pluginManager.getPlugin("swarm")

println JsonOutput.toJson([
    JavaVersion: System.getProperty("java.version"),
    SwarmPluginVersion: (swarmPlugin ? swarmPlugin.version : null),
])'

	python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode({"script": sys.stdin.read()}))' <<EOF >"$body_file"
$script
EOF

	jenkins_fetch_crumb optional
	response=$(jenkins_post /scriptText \
		-H "Content-Type: application/x-www-form-urlencoded" \
		--data-binary @"$body_file" 2>/dev/null || true)
	case "$response" in
	*'"JavaVersion"'*) ;;
	*)
		# A stale or missing crumb is the usual cause; take a fresh one and insist.
		jenkins_fetch_crumb required
		response=$(jenkins_post /scriptText \
			-H "Content-Type: application/x-www-form-urlencoded" \
			--data-binary @"$body_file")
		;;
	esac

	jenkins_session_close
	printf '%s' "$response" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'
}

parse_java_major() {
	python3 -c '
import re, sys
version = sys.argv[1].strip().strip("\"")
if version.startswith("1."):
    print(version.split(".")[1])
else:
    match = re.match(r"(\d+)", version)
    if not match:
        raise SystemExit("invalid Java version %r" % version)
    print(match.group(1))
' "$1"
}

installed_java_major() {
	java_binary=$1
	"$java_binary" -version 2>&1 | python3 -c '
import re, sys
output = sys.stdin.read()
match = re.search(r"version \"([^\"]+)\"", output)
if not match:
    raise SystemExit(1)
version = match.group(1)
if version.startswith("1."):
    print(version.split(".")[1])
else:
    major = re.match(r"(\d+)", version)
    if not major:
        raise SystemExit(1)
    print(major.group(1))
'
}

resolve_temurin_download_url() {
	java_major=$1
	arch=$(machine_arch)
	api_url="https://api.github.com/repos/adoptium/temurin${java_major}-binaries/releases/latest"
	release_json=$(curl -fsSL -H "Accept: application/vnd.github+json" "$api_url")
	needle="OpenJDK${java_major}U-jdk_${arch}_linux_hotspot_"
	printf '%s' "$release_json" | python3 -c '
import json, sys
needle = sys.argv[1]
release = json.load(sys.stdin)
for asset in release.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.startswith(needle) and name.endswith(".tar.gz") and url:
        print(url)
        raise SystemExit(0)
raise SystemExit("no matching Temurin asset for %r" % needle)
' "$needle"
}

install_temurin_java() {
	java_major=$1
	java_home_dir="$AGENT_DIR/java-temurin-$java_major"
	download_url=$(resolve_temurin_download_url "$java_major")
	tmp_dir=$(mktemp -d "$AGENT_DIR/temurin.XXXXXX")
	trap 'rm -rf "$tmp_dir"' EXIT INT TERM

	echo "jenkins-agent runner: downloading Temurin JDK java=$java_major url=$download_url" >&2
	archive="$tmp_dir/temurin.tar.gz"
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors -o "$archive" "$download_url"
	[ -s "$archive" ] || fail "downloaded Temurin archive is empty"
	tar -xzf "$archive" -C "$tmp_dir"
	rm -f "$archive"

	java_home=$tmp_dir
	if [ ! -x "$tmp_dir/bin/java" ]; then
		java_home=""
		for candidate in "$tmp_dir"/*; do
			[ -d "$candidate" ] || continue
			if [ -x "$candidate/bin/java" ]; then
				java_home=$candidate
				break
			fi
		done
		[ -n "$java_home" ] || fail "java home with bin/java not found in Temurin archive"
	fi

	rm -rf "$java_home_dir"
	mv "$java_home" "$java_home_dir"
	chmod 0755 "$java_home_dir/bin/java"
	trap - EXIT INT TERM
}

ensure_matching_java() {
	java_major=$1
	java_home_dir="$AGENT_DIR/java-temurin-$java_major"
	java_binary="$java_home_dir/bin/java"
	local_major=""
	if [ -x "$java_binary" ]; then
		local_major=$(installed_java_major "$java_binary" 2>/dev/null || true)
	fi
	if [ "$local_major" != "$java_major" ]; then
		echo "jenkins-agent runner: local Java does not match the controller; updating java=$java_major" >&2
		install_temurin_java "$java_major"
	fi
	printf '%s' "$java_binary"
}

ensure_matching_swarm_jar() {
	base=$(jenkins_base_url "$JENKINS_URL")
	tmp=$(mktemp "$AGENT_DIR/swarm-client.XXXXXX.jar")
	trap 'rm -f "$tmp"' EXIT INT TERM
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
		-u "$JENKINS_USERNAME:$jenkins_password" \
		"$base/swarm/swarm-client.jar" -o "$tmp"
	[ -s "$tmp" ] || fail "downloaded swarm-client.jar is empty"

	if [ -f "$SWARM_JAR_PATH" ] && cmp -s "$tmp" "$SWARM_JAR_PATH"; then
		rm -f "$tmp"
		echo "jenkins-agent runner: swarm-client.jar matches the controller" >&2
	else
		chmod 0644 "$tmp"
		mv "$tmp" "$SWARM_JAR_PATH"
		echo "jenkins-agent runner: updated swarm-client.jar from the controller" >&2
	fi
	trap - EXIT INT TERM
}

need cmp
need curl
need hostname
need python3
need tar
[ -r "$PASSWORD_FILE" ] || fail "password file is not readable: $PASSWORD_FILE"
jenkins_password=$(tr -d '\r\n' <"$PASSWORD_FILE")
[ -n "$jenkins_password" ] || fail "password file is empty"

controller_info=$(fetch_jenkins_controller_info)
java_version=$(printf '%s' "$controller_info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("JavaVersion",""))')
swarm_version=$(printf '%s' "$controller_info" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("SwarmPluginVersion",""))')
[ -n "$java_version" ] || fail "Jenkins Java version is empty"
[ -n "$swarm_version" ] || fail "Jenkins Swarm plugin is not installed"
java_major=$(parse_java_major "$java_version")

echo "jenkins-agent runner: controller java=$java_version java_major=$java_major swarm_plugin=$swarm_version" >&2
java_binary=$(ensure_matching_java "$java_major")
ensure_matching_swarm_jar

# The JVM replaces this shell, so the service manager's stop signal lands on the
# Swarm client itself. -retry/-retryInterval keep it reconnecting across a
# controller restart instead of exiting; the app is not failed for an outage it
# is expected to ride out.
echo "jenkins-agent runner: starting the Swarm client name=$AGENT_NAME labels=$LABELS" >&2
exec "$java_binary" \
	"-Djava.util.logging.config.file=$LOG_CONFIG_PATH" \
	-jar "$SWARM_JAR_PATH" \
	-name "$AGENT_NAME" \
	-mode exclusive \
	-executors 1 \
	-labels "$LABELS" \
	-fsroot "$AGENT_DIR" \
	-deleteExistingClients \
	-disableClientsUniqueId \
	-retry 5 \
	-retryInterval 10 \
	-master "$JENKINS_URL" \
	-username "$JENKINS_USERNAME" \
	-passwordFile "$PASSWORD_FILE" \
	-webSocket
