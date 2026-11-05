#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: start-jfrog.sh [--url=URL] [--user=NAME] [--token-file=PATH]
                      [--install-dir=DIR]

Checks that the JFrog CLI runs and, given all three of a server URL, a user and
an access token file, configures that server as the CLI's default.

  --url=URL          JFrog Platform base URL, e.g. https://example.jfrog.io
  --user=NAME        JFrog username
  --token-file=PATH  file holding a JFrog access token
  --install-dir=DIR  where install put jf (default: /usr/local/bin)
  --help             show this help
USAGE
}

fail() {
	echo "jfrog configure: $*" >&2
	exit 1
}

usage_error() {
	echo "jfrog configure: $*" >&2
	usage >&2
	exit 2
}

jfrog_url=
jfrog_user=
token_file=
install_dir=/usr/local/bin
for arg; do
	case $arg in
	--url=*) jfrog_url=${arg#--url=} ;;
	--user=*) jfrog_user=${arg#--user=} ;;
	--token-file=*) token_file=${arg#--token-file=} ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done

read_token() {
	if [ -n "$token_file" ]; then
		[ -r "$token_file" ] || fail "the token file is not readable"
		tr -d '\r\n' <"$token_file"
	fi
}

if command -v jf >/dev/null 2>&1; then
	jf_bin=$(command -v jf)
elif [ -x "$install_dir/jf" ]; then
	jf_bin=$install_dir/jf
else
	fail "JFrog CLI is not installed"
fi

"$jf_bin" --version >/dev/null

# Credentials are optional: with none supplied the app's job is done once the
# CLI is installed and runnable. Configuring a server needs all three together.
token=$(read_token)
if [ -z "$jfrog_url" ] && [ -z "$jfrog_user" ] && [ -z "$token" ]; then
	echo "JFrog CLI is ready; credentials were not provided" >&2
	exit 0
fi
[ -n "$jfrog_url" ] || fail "jfrog_url is required to configure a server"
[ -n "$jfrog_user" ] || fail "jfrog_user is required to configure a server"
[ -n "$token" ] || fail "jfrog_token is required to configure a server"

umask 077
echo "Configuring JFrog CLI server 'orc'" >&2
printf '%s' "$token" |
	CI=true "$jf_bin" config add orc \
		--url="$jfrog_url" \
		--user="$jfrog_user" \
		--access-token-stdin \
		--interactive=false \
		--overwrite
unset token

"$jf_bin" config use orc
echo "JFrog CLI configuration complete" >&2
