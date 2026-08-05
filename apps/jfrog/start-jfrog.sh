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
	else
		printf '%s' "${JFROG_TOKEN:-}"
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

"$jf_bin" --version >/dev/null

# Credentials are optional: with none supplied the app's job is done once the
# CLI is installed and runnable. Configuring a server needs all three together.
token=$(read_token)
if [ -z "${JFROG_URL:-}" ] && [ -z "${JFROG_USER:-}" ] && [ -z "$token" ]; then
	echo "JFrog CLI is ready; credentials were not provided" >&2
	exit 0
fi
[ -n "${JFROG_URL:-}" ] || fail "jfrog_url is required to configure a server"
[ -n "${JFROG_USER:-}" ] || fail "jfrog_user is required to configure a server"
[ -n "$token" ] || fail "jfrog_token is required to configure a server"

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
