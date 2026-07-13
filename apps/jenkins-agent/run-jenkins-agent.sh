#!/bin/sh
set -eu

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

jenkins_base_url() {
	url=${JENKINS_URL%/}
	case "$url" in
	http://* | https://*) ;;
	*) fail "Jenkins URL must start with http:// or https://" ;;
	esac
	[ -n "${url#*://}" ] || fail "Jenkins URL host is required"
	printf '%s' "$url"
}

machine_arch() {
	case "$(uname -m)" in
	x86_64 | amd64) printf 'x64' ;;
	aarch64 | arm64) printf 'aarch64' ;;
	*) fail "unsupported architecture $(uname -m)" ;;
	esac
}

fetch_jenkins_controller_info() {
	base=$(jenkins_base_url)
	script_url="$base/scriptText"
	cookie_jar=$(mktemp)
	body_file=$(mktemp)
	trap 'rm -f "$cookie_jar" "$body_file"' EXIT INT TERM

	script='import groovy.json.JsonOutput;

swarmPlugin = Jenkins.instance.pluginManager.getPlugin("swarm")

println JsonOutput.toJson([
    JavaVersion: System.getProperty("java.version"),
    SwarmPluginVersion: (swarmPlugin ? swarmPlugin.version : null),
])'

	python3 -c 'import sys, urllib.parse; print(urllib.parse.urlencode({"script": sys.stdin.read()}))' <<EOF >"$body_file"
$script
EOF

	crumb_field=""
	crumb_value=""
	crumb_json=$(curl -fsS -u "$JENKINS_USERNAME:$jenkins_password" \
		-c "$cookie_jar" -b "$cookie_jar" \
		"$base/crumbIssuer/api/json" 2>/dev/null || true)
	if [ -n "$crumb_json" ]; then
		crumb_field=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumbRequestField",""))')
		crumb_value=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumb",""))')
	fi

	post_script() {
		if [ -n "$crumb_field" ] && [ -n "$crumb_value" ]; then
			curl -fsS -u "$JENKINS_USERNAME:$jenkins_password" \
				-c "$cookie_jar" -b "$cookie_jar" \
				-H "Content-Type: application/x-www-form-urlencoded" \
				-H "$crumb_field: $crumb_value" \
				--data-binary @"$body_file" \
				"$script_url"
		else
			curl -fsS -u "$JENKINS_USERNAME:$jenkins_password" \
				-c "$cookie_jar" -b "$cookie_jar" \
				-H "Content-Type: application/x-www-form-urlencoded" \
				--data-binary @"$body_file" \
				"$script_url"
		fi
	}

	response=$(post_script 2>/dev/null || true)
	case "$response" in
	*'"JavaVersion"'*) ;;
	*)
		crumb_json=$(curl -fsS -u "$JENKINS_USERNAME:$jenkins_password" \
			-c "$cookie_jar" -b "$cookie_jar" \
			"$base/crumbIssuer/api/json")
		crumb_field=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumbRequestField",""))')
		crumb_value=$(printf '%s' "$crumb_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("crumb",""))')
		[ -n "$crumb_field" ] && [ -n "$crumb_value" ] || fail "failed to fetch Jenkins CSRF crumb"
		response=$(post_script)
		;;
	esac

	printf '%s' "$response" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)))'
	rm -f "$cookie_jar" "$body_file"
	trap - EXIT INT TERM
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

	echo "Downloading Temurin JDK $java_major from $download_url" >&2
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
		echo "Local Java does not match Jenkins Java $java_major; updating" >&2
		install_temurin_java "$java_major"
	fi
	printf '%s' "$java_binary"
}

ensure_matching_swarm_jar() {
	base=$(jenkins_base_url)
	tmp=$(mktemp "$AGENT_DIR/swarm-client.XXXXXX.jar")
	trap 'rm -f "$tmp"' EXIT INT TERM
	curl -fsSL --retry 5 --retry-delay 3 --retry-all-errors \
		-u "$JENKINS_USERNAME:$jenkins_password" \
		"$base/swarm/swarm-client.jar" -o "$tmp"
	[ -s "$tmp" ] || fail "downloaded swarm-client.jar is empty"

	if [ -f "$SWARM_JAR_PATH" ] && cmp -s "$tmp" "$SWARM_JAR_PATH"; then
		rm -f "$tmp"
		echo "Local swarm-client.jar matches Jenkins controller" >&2
	else
		chmod 0644 "$tmp"
		mv "$tmp" "$SWARM_JAR_PATH"
		echo "Updated swarm-client.jar from Jenkins controller" >&2
	fi
	trap - EXIT INT TERM
}

need cmp
need curl
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

echo "Jenkins controller Java $java_version (major $java_major), Swarm plugin $swarm_version" >&2
java_binary=$(ensure_matching_java "$java_major")
ensure_matching_swarm_jar

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
	-noRetryAfterConnected \
	-retry 5 \
	-retryInterval 10 \
	-master "$JENKINS_URL" \
	-username "$JENKINS_USERNAME" \
	-passwordFile "$PASSWORD_FILE" \
	-webSocket
