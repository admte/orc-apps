#!/bin/sh
set -eu

fail() {
	echo "jfrog install: $*" >&2
	exit 1
}

if command -v jf >/dev/null 2>&1 && [ -z "${APP_VERSION:-}" ] && [ -z "${JFROG_CLI_FORCE_INSTALL:-}" ]; then
	jf --version
	exit 0
fi
command -v curl >/dev/null 2>&1 || fail "curl is required"

case "$(uname -s)" in
Linux)
	os=linux
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac
	;;
Darwin)
	os=mac
	case "$(uname -m)" in
	x86_64 | amd64) arch=386 ;;
	arm64 | aarch64) arch=arm64 ;;
	*) fail "unsupported architecture: $(uname -m)" ;;
	esac
	;;
*)
	fail "unsupported operating system: $(uname -s)"
	;;
esac

version=${APP_VERSION:-${JFROG_CLI_VERSION:-'[RELEASE]'}}
url="https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/$version/jfrog-cli-$os-$arch/jf"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Downloading JFrog CLI for $os/$arch" >&2
curl -fgLsS "$url" -o "$tmp/jf"
chmod 0755 "$tmp/jf"

install_dir=${JFROG_CLI_INSTALL_DIR:-/usr/local/bin}
mkdir -p "$install_dir"
install -m 0755 "$tmp/jf" "$install_dir/jf"
"$install_dir/jf" --version
