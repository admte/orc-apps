#!/bin/sh
set -eu

fail() {
	echo "jfrog configure: $*" >&2
	exit 1
}

read_token() {
	if [ -n "${JFROG_TOKEN_FILE:-}" ]; then
		[ -r "$JFROG_TOKEN_FILE" ] || fail "JFROG_TOKEN_FILE is not readable"
		tr -d '\r\n' <"$JFROG_TOKEN_FILE"
	elif [ -n "${JFROG_TOKEN:-}" ]; then
		printf '%s' "$JFROG_TOKEN"
	else
		fail "jfrog_token is required"
	fi
}

if command -v jf >/dev/null 2>&1; then
	jf_bin=$(command -v jf)
elif [ -n "${JFROG_CLI_INSTALL_DIR:-}" ] && [ -x "$JFROG_CLI_INSTALL_DIR/jf" ]; then
	jf_bin=$JFROG_CLI_INSTALL_DIR/jf
elif [ -x /usr/local/bin/jf ]; then
	jf_bin=/usr/local/bin/jf
else
	fail "JFrog CLI is not installed"
fi

[ -n "${JFROG_URL:-}" ] || fail "jfrog_url is required"
[ -n "${JFROG_USER:-}" ] || fail "jfrog_user is required"
token=$(read_token)
[ -n "$token" ] || fail "jfrog_token is empty"

umask 077
echo "Configuring JFrog CLI server 'orc'" >&2
printf '%s' "$token" |
	CI=true "$jf_bin" config add orc \
		--url="$JFROG_URL" \
		--user="$JFROG_USER" \
		--access-token-stdin \
		--interactive=false \
		--overwrite
unset token

"$jf_bin" config use orc
echo "JFrog CLI configuration complete" >&2
