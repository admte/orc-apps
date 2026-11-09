#!/bin/sh
set -eu

usage() {
	cat <<'USAGE'
Usage: install-claude.sh [--version=VERSION] [--force] [--install-dir=DIR]

Installs Claude Code. Without --version it installs the latest release, and
leaves a claude command that is already on PATH as it is.

  --version=VERSION  Claude Code release to install, e.g. 2.1.0
  --force            install even when claude is already on PATH
  --install-dir=DIR  where the claude command is installed (default: /usr/local/bin)
  --help             show this help
USAGE
}

fail() {
	echo "claude install: $*" >&2
	exit 1
}

usage_error() {
	echo "claude install: $*" >&2
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

need() {
	command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

if command -v claude >/dev/null 2>&1 &&
	[ -z "$requested" ] &&
	[ -z "$force" ]; then
	claude --version
	exit 0
fi

case "$(uname -s)" in
Linux)
	os=linux
	;;
Darwin)
	os=darwin
	;;
*)
	fail "unsupported operating system: $(uname -s)"
	;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=x64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

need curl
need tar
archive="claude-$os-$arch.tar.gz"
if [ -n "$requested" ]; then
	version=${requested#v}
	base_url="https://github.com/anthropics/claude-code/releases/download/v$version"
else
	base_url="https://github.com/anthropics/claude-code/releases/latest/download"
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
echo "Downloading Claude Code for $os/$arch" >&2
curl -fsSL "$base_url/$archive" -o "$tmp/$archive"
curl -fsSL "$base_url/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"

expected=$(awk -v archive="$archive" '$2 == archive { print $1 }' "$tmp/SHASUMS256.txt")
[ -n "$expected" ] || fail "checksum for $archive was not published"
if command -v sha256sum >/dev/null 2>&1; then
	actual=$(sha256sum "$tmp/$archive" | awk '{ print $1 }')
elif command -v shasum >/dev/null 2>&1; then
	actual=$(shasum -a 256 "$tmp/$archive" | awk '{ print $1 }')
else
	fail "sha256sum or shasum is required"
fi
[ "$actual" = "$expected" ] || fail "checksum verification failed for $archive"

tar -xzf "$tmp/$archive" -C "$tmp"
[ -f "$tmp/claude" ] || fail "Claude Code binary is missing from $archive"

mkdir -p "$install_dir"
install -m 0755 "$tmp/claude" "$install_dir/claude"
"$install_dir/claude" --version
