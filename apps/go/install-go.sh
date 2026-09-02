#!/bin/sh
set -eu

fail() {
	echo "go install: $*" >&2
	exit 1
}

[ -n "${APP_VERSION:-}" ] || fail "APP_VERSION is required"
command -v curl >/dev/null 2>&1 || fail "curl is required"
command -v tar >/dev/null 2>&1 || fail "tar is required"

case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) fail "unsupported architecture: $(uname -m)" ;;
esac

version=${APP_VERSION#go}
case "$version" in
'' | *[!0-9.]* | .* | *..* | *.) fail "invalid APP_VERSION: $APP_VERSION" ;;
esac
asset="go$version.linux-$arch.tar.gz"
base=https://go.dev/dl
root=${GO_INSTALL_ROOT:-/opt/go}
bin_dir=${GO_BIN_DIR:-/usr/local/bin}
prefix="$root/$version"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

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

mkdir -p "$bin_dir"
for name in go gofmt; do
	ln -sfn "$prefix/bin/$name" "$bin_dir/$name"
done

actual_version=$("$prefix/bin/go" version)
case "$actual_version" in
*" go$version "*) ;;
*) fail "installed version '$actual_version' does not match $version" ;;
esac
