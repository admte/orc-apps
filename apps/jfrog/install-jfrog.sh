#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-jfrog.sh [--version=VERSION] [--force] [--install-dir=DIR]

Installs the JFrog CLI (jf). Without --version it installs the latest release,
and leaves a jf command that is already on PATH as it is.

  --version=VERSION  JFrog CLI release to install, e.g. 2.70.0
  --force            install even when jf is already on PATH
  --install-dir=DIR  where jf is installed (default: /usr/local/bin)
  --help             show this help
USAGE
}

fail() {
	echo "jfrog install: $*" >&2
	exit 1
}

usage_error() {
	echo "jfrog install: $*" >&2
	usage >&2
	exit 2
}

requested=
force=
install_dir=/usr/local/bin
for arg; do
	case $arg in
	--version=*) requested=${arg#--version=} ;;
	--force) force=1 ;;
	--install-dir=*) install_dir=${arg#--install-dir=} ;;
	--help) usage; exit 0 ;;
	*) usage_error "unknown argument $arg" ;;
	esac
done
[ -n "$install_dir" ] || usage_error "--install-dir must not be empty"

if command -v jf >/dev/null 2>&1 && [ -z "$requested" ] && [ -z "$force" ]; then
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

version=${requested:-'[RELEASE]'}
url="https://releases.jfrog.io/artifactory/jfrog-cli/v2-jf/$version/jfrog-cli-$os-$arch/jf"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

echo "Downloading JFrog CLI for $os/$arch" >&2
curl -fgLsS "$url" -o "$tmp/jf"
chmod 0755 "$tmp/jf"

mkdir -p "$install_dir"
install -m 0755 "$tmp/jf" "$install_dir/jf"
"$install_dir/jf" --version
