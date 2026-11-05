#!/bin/sh
set -eu

fail() {
	echo "go install: $*" >&2
	exit 1
}

# Progress on stdout: the node log renders an install's stderr as warnings.
note() {
	echo "go install: $*"
}

command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

base=https://go.dev/dl
root=${GO_INSTALL_ROOT:-/opt/go}
bin_dir=${GO_BIN_DIR:-/usr/local/bin}

version=${APP_VERSION:-}
version=${version#go}
if [ -z "$version" ]; then
	# APP_VERSION arrives unset when the request resolved to the implicit
	# `default` tag. `?mode=json` lists the stable releases, newest first.
	note "no version was requested; taking the newest release"
	version=$(curl -fsSL "$base/?mode=json" |
		grep -o '"version"[[:space:]]*:[[:space:]]*"go[0-9][^"]*"' |
		head -1 |
		sed 's/.*"go//; s/"$//') ||
		fail "could not read the newest release from go.dev"
	[ -n "$version" ] || fail "the release list names no version"
	note "newest release is $version"
fi

case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid version: $version" ;;
esac

asset="go$version.linux-$arch.tar.gz"
prefix="$root/$version"

expose() {
	mkdir -p "$bin_dir"
	for name in go gofmt; do
		ln -sfn "$prefix/bin/$name" "$bin_dir/$name"
	done
}

# The pool image is baked straight after this phase and every node is rebuilt
# from that image, which runs the phase again on a disk that already carries the
# toolchain. Without this check each node downloads and unpacks it a second time.
if [ -x "$prefix/bin/go" ] && reported=$("$prefix/bin/go" version 2>/dev/null); then
	case "$reported" in
	*" go$version "*)
		expose
		note "go $version is already installed"
		exit 0
		;;
	esac
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

note "downloading $asset"
curl -fsSL "$base/$asset" -o "$work/$asset"
curl -fsSL "$base/?mode=json&include=all" -o "$work/releases.json"
expected=$(awk -v asset="$asset" '
	/"filename"[[:space:]]*:/ {
		line = $0
		sub(/^.*"filename"[[:space:]]*:[[:space:]]*"/, "", line)
		sub(/".*$/, "", line)
		found = (line == asset)
	}
	found && /"sha256"[[:space:]]*:/ {
		line = $0
		sub(/^.*"sha256"[[:space:]]*:[[:space:]]*"/, "", line)
		sub(/".*$/, "", line)
		print line
		exit
	}
' "$work/releases.json")
[ -n "$expected" ] || fail "checksum for $asset was not published"
actual=$(sha256sum "$work/$asset" | awk '{ print $1 }')
[ "$actual" = "$expected" ] || fail "checksum verification failed for $asset"

rm -rf "$prefix"
mkdir -p "$prefix"
tar -xzf "$work/$asset" --strip-components=1 -C "$prefix"

expose

actual_version=$("$prefix/bin/go" version)
case "$actual_version" in
*" go$version "*) ;;
*) fail "installed version '$actual_version' does not match $version" ;;
esac

note "go $version installed at $prefix"
