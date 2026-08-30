#!/bin/sh
# Shared Jenkins REST helpers for the jenkins-agent app.
#
# Sourced, never executed. A session holds the basic-auth credentials, a cookie
# jar, and the CSRF crumb the controller hands out; every request in a phase
# reuses them, because Jenkins binds the crumb to the session that fetched it.

jenkins_session_dir=""
jenkins_crumb_field=""
jenkins_crumb_value=""
JENKINS_BASE=""
JENKINS_USER=""
JENKINS_PASS=""

jenkins_common_fail() {
	echo "jenkins-agent: $*" >&2
	exit 1
}

# Normalizes a controller URL: drops a trailing slash and rejects anything that
# is not an absolute http(s) URL with a host.
jenkins_base_url() {
	url=${1%/}
	case "$url" in
	http://* | https://*) ;;
	*) jenkins_common_fail "Jenkins URL must start with http:// or https://" ;;
	esac
	[ -n "${url#*://}" ] || jenkins_common_fail "Jenkins URL host is required"
	printf '%s' "$url"
}

jenkins_session_open() {
	JENKINS_BASE=$(jenkins_base_url "$1")
	JENKINS_USER=$2
	JENKINS_PASS=$3
	jenkins_session_dir=$(mktemp -d)
	jenkins_crumb_field=""
	jenkins_crumb_value=""
}

jenkins_session_close() {
	[ -n "$jenkins_session_dir" ] || return 0
	rm -rf "$jenkins_session_dir"
	jenkins_session_dir=""
}

jenkins_json_field() {
	python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1]) or "")' "$1"
}

jenkins_json_bool() {
	python3 -c 'import json,sys; print("true" if json.load(sys.stdin).get(sys.argv[1]) else "false")' "$1"
}

# curl with basic auth and the session cookie jar. Fails the pipeline on an HTTP
# error, so callers that want the status code use jenkins_fetch instead.
jenkins_curl() {
	curl -fsS -u "$JENKINS_USER:$JENKINS_PASS" \
		-c "$jenkins_session_dir/cookies" -b "$jenkins_session_dir/cookies" "$@"
}

# GET that never fails the caller: the body lands in $2 and the HTTP status is
# printed ("000" when the controller could not be reached at all), so a missing
# agent (404) is told apart from an unreachable controller.
jenkins_fetch() {
	curl -sS -u "$JENKINS_USER:$JENKINS_PASS" \
		-c "$jenkins_session_dir/cookies" -b "$jenkins_session_dir/cookies" \
		-o "$2" -w '%{http_code}' "$JENKINS_BASE$1" 2>/dev/null || printf '000'
}

# Fetches a CSRF crumb into the session. Tolerant by default (a controller with
# CSRF protection disabled answers 404); "required" fails when none comes back.
jenkins_fetch_crumb() {
	jenkins_crumb_field=""
	jenkins_crumb_value=""
	crumb_json=$(jenkins_curl "$JENKINS_BASE/crumbIssuer/api/json" 2>/dev/null || true)
	if [ -n "$crumb_json" ]; then
		jenkins_crumb_field=$(printf '%s' "$crumb_json" | jenkins_json_field crumbRequestField)
		jenkins_crumb_value=$(printf '%s' "$crumb_json" | jenkins_json_field crumb)
	fi
	if [ "${1:-optional}" = required ] &&
		{ [ -z "$jenkins_crumb_field" ] || [ -z "$jenkins_crumb_value" ]; }; then
		jenkins_common_fail "failed to fetch the Jenkins CSRF crumb"
	fi
}

jenkins_post() {
	path=$1
	shift
	if [ -n "$jenkins_crumb_field" ] && [ -n "$jenkins_crumb_value" ]; then
		jenkins_curl -X POST -H "$jenkins_crumb_field: $jenkins_crumb_value" \
			"$@" "$JENKINS_BASE$path"
	else
		jenkins_curl -X POST "$@" "$JENKINS_BASE$path"
	fi
}
